# frozen_string_literal: true

require "uri"

module ChConnect
  # Configuration for ClickHouse connection.
  #
  # @example
  #   config = ChConnect::Config.new(host: "db.example.com", port: 9000)
  #
  # @example Using URL
  #   config = ChConnect::Config.new
  #   config.url = "http://user:pass@localhost:8123/mydb"
  class Config
    DEFAULTS = {
      transport: :http,
      scheme: "http",
      host: "localhost",
      port: 8123,
      tcp_port: 9000,
      compression: :lz4,
      ssl: false,
      ssl_verify: true,
      ssl_ca: nil,
      database: "default",
      username: "",
      password: "",
      connection_timeout: 5,
      read_timeout: 60,
      write_timeout: 60,
      keep_alive_timeout: 8,
      pool_size: 100,
      pool_timeout: 5,
      max_retries: 3,
      instrumenter: NullInstrumenter.new
    }.freeze

    # @return [String] URL scheme (http or https)
    # @return [String] ClickHouse server hostname
    # @return [Integer] ClickHouse server port
    # @return [String] Database name
    # @return [String] Username for authentication
    # @return [String] Password for authentication
    # @return [Integer] Connection timeout in seconds
    # @return [Integer] Read timeout in seconds
    # @return [Integer] Write timeout in seconds
    # @return [Integer] Keep-alive timeout for idle persistent connections in seconds
    # @return [Integer] Connection pool size
    # @return [Integer] Pool checkout timeout in seconds
    # @return [Integer] Max retry attempts on connection errors
    # @return [#instrument] Instrumenter for query instrumentation
    # @return [Symbol] Transport to use: :http (default) or :native (TCP protocol, requires compiled extension)
    # @return [Integer] Native TCP protocol port (used when transport is :native)
    # @return [Symbol, nil] Block compression for :native transport: :lz4 (default), :zstd or nil
    # @return [Boolean] Use TLS for the :native transport (default: false)
    # @return [Boolean] Verify the server certificate when ssl is enabled (default: true)
    # @return [String, nil] Path to a CA certificate file for TLS verification (default: system CA store)
    attr_accessor :tcp_port, :compression, :ssl, :ssl_verify, :ssl_ca, :scheme, :host, :port, :database, :username, :password, :connection_timeout, :read_timeout, :write_timeout, :keep_alive_timeout, :pool_size, :pool_timeout, :max_retries, :instrumenter
    attr_reader :transport

    # Creates a new configuration instance.
    #
    # @param params [Hash] configuration options
    # @option params [String] :scheme URL scheme (default: "http")
    # @option params [String] :host server hostname (default: "localhost")
    # @option params [Integer] :port server port (default: 8123)
    # @option params [String] :database database name (default: "default")
    # @option params [String] :username authentication username (default: "")
    # @option params [String] :password authentication password (default: "")
    # @option params [Integer] :connection_timeout connection timeout in seconds (default: 5)
    # @option params [Integer] :read_timeout read timeout in seconds (default: 60)
    # @option params [Integer] :write_timeout write timeout in seconds (default: 60)
    # @option params [Integer] :keep_alive_timeout idle persistent connection timeout in seconds (default: 8)
    # @option params [Integer] :pool_size connection pool size (default: 100)
    # @option params [Integer] :pool_timeout pool checkout timeout (default: 5)
    # @option params [Integer] :max_retries max retry attempts on connection errors (default: 3)
    def initialize(params = {})
      DEFAULTS.merge(params).each do |key, value|
        send("#{key}=", value)
      end
    end

    # Sets configuration from a URL string.
    #
    # @param url [String] ClickHouse connection URL
    # @return [void]
    def url=(url)
      uri = URI(url)
      native_scheme = %w[clickhouse clickhouses tcp tcps].include?(uri.scheme)
      secure = %w[https clickhouses tcps].include?(uri.scheme)

      # Remember the endpoint so transport can be assigned after url without
      # changing the dormant native defaults of an HTTP-only configuration.
      @url_tcp_port = uri.port || (secure ? 9440 : 9000) if native_scheme
      @url_tcp_port = uri.port if %w[http https].include?(uri.scheme)
      @url_ssl = secure if native_scheme || %w[http https].include?(uri.scheme)

      if native_scheme
        self.transport = :native
        # Keep the HTTP fields coherent if the transport is changed later.
        @scheme = secure ? "https" : "http"
        @port = uri.port || (secure ? 8443 : 8123)
      else
        @scheme = uri.scheme
        @port = uri.port
        apply_url_to_native if @transport == :native
      end
      @host = uri.host
      @database = uri.path.delete_prefix("/")
      @username = uri.user
      @password = uri.password
    end

    # Selects the transport. A previously assigned URL becomes the native
    # endpoint at this point, making url/transport assignment order irrelevant.
    def transport=(transport)
      @transport = transport
      apply_url_to_native if transport == :native
    end

    private

    def apply_url_to_native
      @tcp_port = @url_tcp_port if @url_tcp_port
      @ssl = @url_ssl unless @url_ssl.nil?
    end
  end
end
