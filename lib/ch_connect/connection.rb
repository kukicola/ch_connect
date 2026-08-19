# frozen_string_literal: true

require "connection_pool"
require "openssl"
require "socket"

module ChConnect
  # A pooled ClickHouse connection built on the clickhouse-c ioless client:
  # the C extension is a pure protocol state machine + block decoder, and all
  # socket I/O, TLS, and timeouts live here in Ruby. Result blocks are parsed
  # in C.
  #
  # Maintains a pool of connections (config.pool_size); the native protocol
  # handles one query at a time per connection, so concurrent queries each
  # check out their own connection.
  class Connection
    # Connection establishment failures are safe to retry because no query
    # bytes have been sent to the server yet.
    class EstablishmentError < ConnectionError; end
    private_constant :EstablishmentError

    COMPRESSION_AVAILABLE = {
      nil => true,
      :lz4 => NativeClient::LZ4_AVAILABLE,
      :zstd => NativeClient::ZSTD_AVAILABLE
    }.freeze

    READ_CHUNK = 64 * 1024
    WRITE_CHUNK = 64 * 1024
    PARAM_ESCAPES = {
      "\0" => "\\0", "\a" => "\\a", "\b" => "\\b", "\e" => "\\e",
      "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t",
      "\v" => "\\v", "'" => "\\'", "\\" => "\\\\"
    }.freeze
    PARAM_ESCAPE_PATTERN = /[\0\a\b\e\f\n\r\t\v'\\]/
    RESERVED_SETTINGS = {
      "network_compression_method" => "set config.compression instead",
      "output_format_native_encode_types_in_binary_format" => "required by the native decoder"
    }.freeze

    # A pooled slot owning one socket + protocol state machine pair.
    # Connects lazily and replaces the connection when it is broken or was
    # abandoned mid-query (interrupt, timeout, killed thread) — the C client
    # tracks both via broken?.
    # @api private
    class Slot
      def initialize(config)
        @config = config
        @socket = nil
        @client = nil
        @pid = Process.pid
        @read_buf = String.new(capacity: READ_CHUNK)
      end

      def query(sql, params, settings)
        ensure_connected

        @client.send_query(sql, params, settings)
        flush_output
        loop do
          case @client.recv_step
          when :done then break
          when :want_read then @client.feed(read_chunk)
          end
        end
        @client.take_result
      rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "#{e.class}: #{e.message}"
      end

      def broken? = !@client || @client.broken? || @socket&.closed?

      def close
        if @pid != Process.pid && @socket.is_a?(OpenSSL::SSL::SSLSocket)
          # A fork duplicates the fd. Closing the SSLSocket would send a TLS
          # close_notify on the parent's live session; close only this process's
          # raw fd instead.
          safe_close(@socket.to_io)
        else
          safe_close(@socket)
        end
        @client&.close
        @socket = nil
        @client = nil
      end

      private

      def ensure_connected
        if @client
          raise EstablishmentError, "pooled connection is broken" if broken?

          return
        end

        establish_connection
      end

      def establish_connection
        @socket = connect_socket
        @client = NativeClient.new(
          @config.database,
          @config.username,
          @config.password,
          @config.compression
        )
        handshake
      rescue ConnectionError, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        close
        raise EstablishmentError, "#{e.class}: #{e.message}"
      end

      def connect_socket
        socket = Socket.tcp(@config.host, @config.port, connect_timeout: @config.connection_timeout)
        wrapped = nil
        begin
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          wrapped = @config.ssl ? tls_wrap(socket) : socket
        ensure
          # a failed TLS handshake would otherwise leak the raw socket:
          # @socket is not assigned yet, so discard has nothing to close.
          # (ensure, not rescue: Thread#kill / Timeout skip rescue clauses)
          safe_close(socket) if wrapped.nil?
        end
        wrapped
      end

      def tls_wrap(socket)
        ctx = OpenSSL::SSL::SSLContext.new
        if @config.ssl_verify
          ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
          ctx.verify_hostname = true
          if @config.ssl_ca
            ctx.ca_file = @config.ssl_ca
          else
            ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
          end
        else
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
        ssl.hostname = @config.host
        ssl.sync_close = true

        deadline = monotonic_now + @config.connection_timeout
        loop do
          readiness = ssl.connect_nonblock(exception: false)
          break unless readiness == :wait_readable || readiness == :wait_writable

          wait_or_fail(ssl, readiness, deadline - monotonic_now, "TLS handshake timeout")
        end
        ssl
      end

      def handshake
        deadline = monotonic_now + @config.connection_timeout
        loop do
          state = @client.handshake_step
          flush_output
          break if state == :done

          # the handshake is part of connecting: bound it by connection_timeout
          remaining = deadline - monotonic_now
          raise ConnectionError, "native handshake timeout" if remaining <= 0

          @client.feed(read_chunk(remaining))
        end
      end

      def flush_output
        deadline = monotonic_now + @config.write_timeout if @config.write_timeout
        while (out = @client.take_output)
          offset = 0
          while offset < out.bytesize
            if deadline && deadline - monotonic_now <= 0
              raise ConnectionError, "write timeout"
            end

            pending = out.byteslice(offset, [WRITE_CHUNK, out.bytesize - offset].min)
            case (written = @socket.write_nonblock(pending, exception: false))
            when :wait_readable, :wait_writable
              remaining = deadline && (deadline - monotonic_now)
              wait_or_fail(@socket, written, remaining, "write timeout")
            else
              raise ConnectionError, "connection closed while writing" if written == 0

              offset += written
            end
          end
        end
      end

      # Reads into a reusable buffer: feed copies the bytes synchronously,
      # so the buffer never needs to survive past the next read.
      def read_chunk(timeout = @config.read_timeout)
        deadline = monotonic_now + timeout if timeout
        loop do
          case (chunk = @socket.read_nonblock(READ_CHUNK, @read_buf, exception: false))
          when :wait_readable, :wait_writable
            remaining = deadline && (deadline - monotonic_now)
            wait_or_fail(@socket, chunk, remaining, "read timeout")
          when nil
            raise ConnectionError, "connection closed by server"
          else
            return chunk
          end
        end
      end

      # readiness is :wait_readable / :wait_writable — also the names of the
      # IO wait methods.
      def wait_or_fail(io, readiness, timeout, message)
        raise ConnectionError, message if timeout && timeout <= 0

        raise ConnectionError, message unless io.to_io.public_send(readiness, timeout)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def safe_close(io)
        io&.close
      rescue IOError, SystemCallError
        nil
      end
    end
    private_constant :Slot

    # @return [Config] the configuration used by this connection
    attr_reader :config

    # Creates a new connection.
    #
    # @param config [Config] configuration instance (defaults to global config)
    def initialize(config = ChConnect.config)
      @config = config.dup.freeze
      validate_compression!
      @codec_name = @config.compression&.to_s&.upcase
      @pool = ConnectionPool.new(
        size: @config.pool_size,
        timeout: @config.pool_timeout,
        auto_reload_after_fork: true
      ) do
        Slot.new(@config)
      end
    end

    # Executes and instruments a SQL query.
    #
    # @param sql [String] SQL query to execute
    # @param params [Hash, nil] query parameters (name => value)
    # @param settings [Hash, nil] per-query ClickHouse settings
    # @param idempotent [Boolean] retry transport failures on a fresh connection
    #   up to config.max_retries (default: false)
    # @return [Response] fully parsed response
    # @raise [QueryError] if the query fails
    # @raise [ConnectionError] if a connection or transport operation fails
    def query(sql, params: nil, settings: nil, idempotent: false)
      @config.instrumenter.instrument("query.clickhouse", {sql: sql}) do
        execute_query(sql, params, settings, idempotent)
      end
    end

    # Closes all pooled connections.
    #
    # @return [void]
    def close
      @pool.shutdown(&:close)
    end

    private

    def execute_query(sql, user_params, user_settings, idempotent)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      params = format_params(user_params)
      settings = format_settings(user_settings)
      retries = 0
      reap_idle_connections

      columns, types, rows, summary = begin
        @pool.with do |slot|
          slot.query(sql, params, settings)
        ensure
          @pool.discard_current_connection(&:close) if slot.broken?
        end
      rescue EstablishmentError
        raise if retries >= @config.max_retries
        retries += 1
        backoff_before_retry(retries)
        retry
      rescue ConnectionError
        raise unless idempotent
        raise if retries >= @config.max_retries
        retries += 1
        backoff_before_retry(retries)
        retry
      rescue ConnectionPool::TimeoutError => e
        raise ConnectionError, "could not obtain a TCP connection from the pool: #{e.message}"
      end
      summary[:client_elapsed_ns] = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started_at
      Response.new(columns: columns, types: types, rows: rows, summary: summary)
    end

    def reap_idle_connections
      timeout = @config.keep_alive_timeout
      @pool.reap(idle_seconds: timeout, &:close) if timeout
    end

    def backoff_before_retry(retry_number)
      base = @config.retry_base_interval
      return unless base.positive?

      ceiling = [base * (2**(retry_number - 1)), @config.retry_max_interval].min
      sleep(ceiling * (0.5 + rand * 0.5))
    end

    def validate_compression!
      available = COMPRESSION_AVAILABLE.fetch(@config.compression) do
        raise Error, "unknown compression: #{@config.compression.inspect} (use :lz4, :zstd or nil)"
      end
      compression = @config.compression
      unless available
        raise Error, "compression = #{compression.inspect} but the extension was built without lib#{compression} (install #{compression} and reinstall the gem, or set config.compression = nil)"
      end
    end

    # Converts params into native protocol substitutions. Values go through
    # Field::restoreFromDump on the server, so everything is sent as a quoted
    # string and converted by the placeholder type (same convention as
    # clickhouse-cpp).
    def format_params(params)
      return nil if params.nil? || params.empty?

      params.map { |name, value| [name.to_s, quote_param(value)] }
    end

    def quote_param(value)
      # Query parameters use Field::restoreFromDump. Its nullable marker is a
      # quoted, doubly escaped text NULL, matching ClickHouse's native client
      # protocol (the dump parser consumes the first escape layer).
      return "'\\\\N'" if value.nil?

      inner_dump = value.is_a?(Array) ? dump_array_value(value) : escape_param_string(value.to_s)
      outer_dump = inner_dump.gsub(/['\\]/) { |char| "\\#{char}" }
      "'".b << outer_dump << "'"
    end

    def dump_array_value(value)
      case value
      when nil then "NULL"
      when Array
        dump = +"[".b
        value.each_with_index do |element, index|
          dump << "," unless index.zero?
          dump << dump_array_value(element)
        end
        dump << "]"
      when String, Symbol then quote_array_string(value.to_s)
      when Time, DateTime
        raise ArgumentError, "#{value.class} array parameters are ambiguous; pass a formatted String"
      when Date then quote_array_string(value.to_s)
      when true then "true"
      when false then "false"
      when Integer, Float, BigDecimal then value.to_s
      else
        raise ArgumentError, "unsupported array parameter element: #{value.class}"
      end
    end

    def quote_array_string(value)
      "'".b << escape_param_string(value) << "'"
    end

    def escape_param_string(value)
      value.b.gsub(PARAM_ESCAPE_PATTERN, PARAM_ESCAPES)
    end

    # Settings travel as name/value strings in the Query packet. The wire's
    # compression flag is boolean and the server picks the response codec
    # from network_compression_method, so when compression is on we set its
    # default to the configured codec.
    def format_settings(user_settings)
      settings = []
      settings << ["network_compression_method", @codec_name] if @codec_name

      user_settings&.each do |key, value|
        name = key.to_s
        if (guidance = RESERVED_SETTINGS[name])
          raise ArgumentError, "setting #{name.inspect} is managed by ch_connect; #{guidance}"
        end
        formatted = case value
        when true then "1"
        when false then "0"
        else value.to_s
        end
        settings << [name, formatted]
      end

      settings.empty? ? nil : settings
    end
  end
end
