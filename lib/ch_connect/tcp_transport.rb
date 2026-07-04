# frozen_string_literal: true

require "connection_pool"
require "openssl"
require "socket"

module ChConnect
  # TCP (native protocol) transport built on the clickhouse-c ioless client:
  # the C extension is a pure protocol state machine + block decoder, and all
  # socket I/O, TLS, and timeouts live here in Ruby. Result blocks are parsed
  # in C.
  #
  # Maintains a pool of connections (config.pool_size); the native protocol
  # handles one query at a time per connection, so concurrent queries each
  # check out their own connection.
  # @api private
  class TcpTransport
    # Maps config.compression to the chc_compression enum in the extension.
    COMPRESSION_CODES = {nil => 0, :lz4 => 1, :zstd => 2}.freeze

    READ_CHUNK = 64 * 1024

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
        discard
        raise ConnectionError, "#{e.class}: #{e.message}"
      rescue ConnectionError
        discard
        raise
      ensure
        # a non-local exit (Thread#kill, Interrupt, Timeout) skips the rescues
        # above but leaves the client mid-stream; close immediately instead of
        # waiting for this slot's next checkout
        discard if @client&.broken?
      end

      def close
        discard
      end

      private

      def ensure_connected
        discard if @client&.broken? || @socket&.closed?
        return if @client

        @socket = connect_socket
        @client = NativeClient.new(
          @config.database,
          normalized_username,
          @config.password || "",
          @compression_code
        )
        handshake
      end

      def normalized_username
        username = @config.username
        (username.nil? || username.empty?) ? "default" : username
      end

      def connect_socket
        socket = Socket.tcp(@config.host, @config.tcp_port, connect_timeout: @config.connection_timeout)
        wrapped = nil
        begin
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          wrapped = @config.ssl ? tls_wrap(socket) : socket
        ensure
          # a failed TLS handshake would otherwise leak the raw socket:
          # @socket is not assigned yet, so discard has nothing to close
          if wrapped.nil?
            begin
              socket.close
            rescue IOError, SystemCallError
              nil
            end
          end
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
        loop do
          state = @client.handshake_step
          flush_output
          break if state == :done

          # the handshake is part of connecting: bound it by connection_timeout
          @client.feed(read_chunk(@config.connection_timeout))
        end
      end

      def flush_output
        while (out = @client.take_output)
          @socket.write(out)
        end
      end

      # Reads into a reusable buffer: feed copies the bytes synchronously,
      # so the buffer never needs to survive past the next read.
      def read_chunk(timeout = @config.read_timeout)
        loop do
          case (chunk = @socket.read_nonblock(READ_CHUNK, @read_buf, exception: false))
          when :wait_readable, :wait_writable
            wait_or_fail(@socket, chunk, timeout, "read timeout")
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

        plain = io.respond_to?(:to_io) ? io.to_io : io
        raise ConnectionError, message unless plain.public_send(readiness, timeout)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def discard
        begin
          @socket&.close
        rescue IOError, SystemCallError
          nil
        end
        @client&.close
        @socket = nil
        @client = nil
      end
    end

    # Creates a new TCP transport.
    #
    # @param config [Config] configuration instance
    def initialize(config)
      @config = config
      load_native_extension
      compression_code = validate_compression!
      @pool = ConnectionPool.new(size: config.pool_size, timeout: config.pool_timeout) do
        Slot.new(config, compression_code)
      end
    end

    # Executes a SQL query over the native TCP protocol.
    #
    # @param sql [String] SQL query to execute
    # @param options [Hash] query options
    # @option options [Hash] :params query parameters (param_name => value)
    # @option options [Hash] :settings per-query ClickHouse settings
    # @return [Response] fully parsed response
    # @raise [QueryError] if the query fails
    def query(sql, options = {})
      params = format_params(options[:params])
      settings = format_settings(options[:settings])
      retries = 0

      begin
        @pool.with do |slot|
          columns, types, rows, summary = slot.query(sql, params, settings)
          Response.new(columns: columns, types: types, rows: rows, summary: summary)
        end
      rescue ConnectionError
        raise if retries >= @config.max_retries
        retries += 1
        retry
      rescue ConnectionPool::TimeoutError => e
        raise ConnectionError, "could not obtain a TCP connection from the pool: #{e.message}"
      end
    end

    # Closes all pooled connections.
    #
    # @return [void]
    def close
      @pool.shutdown(&:close)
    end

    private

    def load_native_extension
      return if defined?(ChConnect::NativeClient)

      require "ch_connect/ch_connect_native"
    rescue LoadError => e
      raise Error, "transport = :native requires the compiled ch_connect_native extension: #{e.message}"
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
    # the ClickHouse HTTP convention (param_<name> => value), so the prefix is
    # stripped here to recover the bare substitution name. Values go through
    # Field::restoreFromDump on the server, so everything is sent as a quoted
    # string and converted by the placeholder type (same convention as
    # clickhouse-cpp).
    def format_params(params)
      return nil if params.nil? || params.empty?

      params.map do |key, value|
        [key.to_s.delete_prefix("param_"), quote_param(value)]
      end
    end

    def quote_param(value)
      return "NULL" if value.nil?

      "'#{value.to_s.gsub(/['\\]/) { |c| "\\#{c}" }}'"
    end

    # Settings travel as name/value strings in the Query packet.
    def format_settings(settings)
      return nil if settings.nil? || settings.empty?

      settings.map do |key, value|
        formatted = case value
        when true then "1"
        when false then "0"
        else value.to_s
        end
        [key.to_s, formatted]
      end
    end
  end
end
