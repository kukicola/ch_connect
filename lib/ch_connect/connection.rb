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

    # Maps config.compression to the chc_compression enum in the extension.
    COMPRESSION_CODES = {nil => 0, :lz4 => 1, :zstd => 2}.freeze

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
      def initialize(config, compression_code)
        @config = config
        @compression_code = compression_code
        @socket = nil
        @client = nil
        @pid = Process.pid
        @last_used_at = nil
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
        result = @client.take_result
        @last_used_at = monotonic_now
        result
      rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "#{e.class}: #{e.message}"
      ensure
        # a non-local exit (Thread#kill, Interrupt, Timeout) skips the rescues
        # above but leaves the client mid-stream; close immediately.
        discard if @client&.broken?
      end

      def close
        discard(inherited: @pid != Process.pid)
      end

      private

      def ensure_connected
        if @pid != Process.pid
          discard(inherited: true)
          @pid = Process.pid
        end
        discard if idle?
        discard if @client&.broken? || @socket&.closed?
        return if @client

        establish_connection
      end

      def establish_connection
        @socket = connect_socket
        @client = NativeClient.new(
          @config.database,
          normalized_username,
          @config.password || "",
          @compression_code
        )
        handshake
        @last_used_at = monotonic_now
      rescue ConnectionError, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
        discard
        raise EstablishmentError, "#{e.class}: #{e.message}"
      end

      def normalized_username
        username = @config.username
        (username.nil? || username.empty?) ? "default" : username
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
          out_offset = 0
          while out_offset < out.bytesize
            chunk = out.byteslice(out_offset, [WRITE_CHUNK, out.bytesize - out_offset].min)
            chunk_offset = 0
            while chunk_offset < chunk.bytesize
              if deadline && deadline - monotonic_now <= 0
                raise ConnectionError, "write timeout"
              end

              pending = (chunk_offset == 0) ? chunk : chunk.byteslice(chunk_offset, chunk.bytesize - chunk_offset)
              case (written = @socket.write_nonblock(pending, exception: false))
              when :wait_readable, :wait_writable
                remaining = deadline && (deadline - monotonic_now)
                wait_or_fail(@socket, written, remaining, "write timeout")
              else
                raise ConnectionError, "connection closed while writing" if written == 0

                chunk_offset += written
              end
            end
            out_offset += chunk.bytesize
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

      def idle?
        timeout = @config.keep_alive_timeout
        @client && timeout && @last_used_at && monotonic_now - @last_used_at >= timeout
      end

      def discard(inherited: false)
        if inherited && @socket.is_a?(OpenSSL::SSL::SSLSocket)
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
        @last_used_at = nil
      end

      def safe_close(io)
        io&.close
      rescue IOError, SystemCallError
        nil
      end
    end

    # @return [Config] the configuration used by this connection
    attr_reader :config

    # Creates a new connection.
    #
    # @param config [Config] configuration instance (defaults to global config)
    def initialize(config = ChConnect.config)
      @config = config
      compression_code = validate_compression!
      @codec_name = (compression_code == 0) ? nil : config.compression.to_s
      @pool = ConnectionPool.new(size: config.pool_size, timeout: config.pool_timeout) do
        Slot.new(config, compression_code)
      end
    end

    # Executes and instruments a SQL query.
    #
    # @param sql [String] SQL query to execute
    # @param options [Hash] query options
    # @option options [Hash] :params query parameters (param_name => value)
    # @option options [Hash] :settings per-query ClickHouse settings
    # @return [Response] fully parsed response
    # @raise [QueryError] if the query fails
    def query(sql, options = {})
      @config.instrumenter.instrument("query.clickhouse", {sql: sql}) do
        execute_query(sql, options)
      end
    end

    # Closes all pooled connections.
    #
    # @return [void]
    def close
      @pool.shutdown(&:close)
    end

    private

    def execute_query(sql, options)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      params = format_params(options[:params])
      settings = format_settings(options[:settings])
      retries = 0

      response = begin
        @pool.with do |slot|
          columns, types, rows, summary = slot.query(sql, params, settings)
          Response.new(columns: columns, types: types, rows: rows, summary: summary)
        end
      rescue EstablishmentError
        raise if retries >= @config.max_retries
        retries += 1
        retry
      rescue ConnectionPool::TimeoutError => e
        raise ConnectionError, "could not obtain a TCP connection from the pool: #{e.message}"
      end
      response.summary[:client_elapsed_ns] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000_000_000).to_i.to_s
      response
    end

    def validate_compression!
      code = COMPRESSION_CODES.fetch(@config.compression) do
        raise Error, "unknown compression: #{@config.compression.inspect} (use :lz4, :zstd or nil)"
      end
      if @config.compression == :lz4 && !NativeClient::LZ4_AVAILABLE
        raise Error, "compression = :lz4 but the extension was built without liblz4 (install lz4 and reinstall the gem, or set config.compression = nil)"
      end
      if @config.compression == :zstd && !NativeClient::ZSTD_AVAILABLE
        raise Error, "compression = :zstd but the extension was built without libzstd (install zstd and reinstall the gem, or set config.compression = nil)"
      end
      code
    end

    # Converts params into native protocol substitutions. The public API uses
    # param_<name> keys, so the prefix is stripped here to recover the bare
    # substitution name. Values go through
    # Field::restoreFromDump on the server, so everything is sent as a quoted
    # string and converted by the placeholder type (same convention as
    # clickhouse-cpp).
    def format_params(params)
      return nil if params.nil? || params.empty?

      params.map do |key, value|
        name = key.to_s
        unless name.start_with?("param_")
          raise ArgumentError, "query parameter #{name.inspect} must use the param_ prefix; pass ClickHouse settings via settings:"
        end

        [name.delete_prefix("param_"), quote_param(value)]
      end
    end

    def quote_param(value)
      # Query parameters use Field::restoreFromDump. Its nullable marker is a
      # quoted, doubly escaped text NULL, matching ClickHouse's native client
      # protocol (the dump parser consumes the first escape layer).
      return "'\\\\N'" if value.nil?

      inner_dump = value.to_s.gsub(PARAM_ESCAPE_PATTERN, PARAM_ESCAPES)
      outer_dump = inner_dump.gsub(/['\\]/) { |char| "\\#{char}" }
      "'#{outer_dump}'"
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
