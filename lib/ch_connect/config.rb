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
  #   config.url = "clickhouse://user:pass@localhost:9000/mydb"
  class Config
    URL_SCHEMES = {
      "clickhouse" => false,
      "tcp" => false,
      "clickhouses" => true,
      "tcps" => true
    }.freeze

    DEFAULTS = {
      host: "localhost",
      port: nil,
      compression: :lz4,
      ssl: false,
      ssl_verify: true,
      ssl_ca: nil,
      database: "default",
      username: "default",
      password: "",
      connection_timeout: 5,
      read_timeout: 60,
      write_timeout: 60,
      keep_alive_timeout: 60,
      pool_size: 100,
      pool_timeout: 5,
      max_retries: 3,
      retry_base_interval: 0.05,
      retry_max_interval: 1.0,
      instrumenter: NullInstrumenter.new
    }.freeze

    # @return [String] ClickHouse server hostname
    # @return [Integer] ClickHouse server port
    # @return [String] Database name
    # @return [String] Username for authentication
    # @return [String] Password for authentication
    # @return [Integer] Connection timeout in seconds
    # @return [Integer] Read timeout in seconds
    # @return [Integer] Write timeout in seconds
    # @return [Numeric, nil] Maximum pooled connection idle time in seconds
    # @return [Integer] Connection pool size
    # @return [Integer] Pool checkout timeout in seconds
    # @return [Integer] Max retries for establishment failures and opted-in
    #   idempotent query transport failures
    # @return [Numeric] Initial retry delay in seconds; zero disables backoff
    # @return [Numeric] Maximum retry delay in seconds
    # @return [#instrument] Instrumenter for query instrumentation
    # @return [Integer] Native protocol port
    # @return [Symbol, nil] Block compression: :lz4 (default), :zstd or nil
    # @return [Boolean] Use TLS (default: false)
    # @return [Boolean] Verify the server certificate when ssl is enabled (default: true)
    # @return [String, nil] Path to a CA certificate file for TLS verification (default: system CA store)
    attr_accessor :compression, :ssl, :ssl_verify, :ssl_ca, :host, :database, :username, :password, :connection_timeout, :read_timeout, :write_timeout, :keep_alive_timeout, :pool_size, :pool_timeout, :max_retries, :retry_base_interval, :retry_max_interval, :instrumenter
    attr_writer :port

    # Creates a new configuration instance.
    #
    # @param params [Hash] configuration options
    # @option params [String] :host server hostname (default: "localhost")
    # @option params [Integer, nil] :port native endpoint port (default: 9000, or 9440 with TLS)
    # @option params [String] :database database name (default: "default")
    # @option params [String] :username authentication username (default: "default")
    # @option params [String] :password authentication password (default: "")
    # @option params [Integer] :connection_timeout connection timeout in seconds (default: 5)
    # @option params [Integer] :read_timeout read timeout in seconds (default: 60)
    # @option params [Integer] :write_timeout write timeout in seconds (default: 60)
    # @option params [Numeric, nil] :keep_alive_timeout pooled TCP connection idle timeout (default: 60)
    # @option params [Integer] :pool_size connection pool size (default: 100)
    # @option params [Integer] :pool_timeout pool checkout timeout (default: 5)
    # @option params [Integer] :max_retries max retries for establishment
    #   failures and opted-in idempotent query transport failures (default: 3)
    # @option params [Numeric] :retry_base_interval initial retry delay in
    #   seconds, with exponential backoff and jitter (default: 0.05)
    # @option params [Numeric] :retry_max_interval maximum retry delay in
    #   seconds (default: 1.0)
    def initialize(params = {})
      DEFAULTS.merge(params).each do |key, value|
        send("#{key}=", value)
      end
    end

    # Returns the explicitly configured port or the default for the active
    # TLS mode.
    def port
      @port || default_port
    end

    # Sets configuration from a URL string.
    #
    # @param url [String] ClickHouse connection URL
    # @return [void]
    def url=(url)
      uri = URI(url)
      ssl = URL_SCHEMES.fetch(uri.scheme) do
        raise ArgumentError, "unsupported ClickHouse URL scheme: #{uri.scheme.inspect}"
      end

      @ssl = ssl
      @port = uri.port
      @host = uri.host
      database = uri.path.delete_prefix("/")
      @database = database unless database.empty?
      @username = uri.user if uri.user
      @password = uri.password if uri.password
    end

    private

    def default_port
      ssl ? 9440 : 9000
    end
  end
end
