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
      "clickhouse" => [false, 9000],
      "tcp" => [false, 9000],
      "clickhouses" => [true, 9440],
      "tcps" => [true, 9440]
    }.transform_values(&:freeze).freeze

    DEFAULTS = {
      host: "localhost",
      port: nil,
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
      pool_size: 100,
      pool_timeout: 5,
      max_retries: 3,
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
    # @return [Integer] Connection pool size
    # @return [Integer] Pool checkout timeout in seconds
    # @return [Integer] Max retry attempts on connection errors
    # @return [#instrument] Instrumenter for query instrumentation
    # @return [Integer] Native protocol port
    # @return [Symbol, nil] Block compression: :lz4 (default), :zstd or nil
    # @return [Boolean] Use TLS (default: false)
    # @return [Boolean] Verify the server certificate when ssl is enabled (default: true)
    # @return [String, nil] Path to a CA certificate file for TLS verification (default: system CA store)
    attr_accessor :compression, :ssl, :ssl_verify, :ssl_ca, :host, :database, :username, :password, :connection_timeout, :read_timeout, :write_timeout, :pool_size, :pool_timeout, :max_retries, :instrumenter
    attr_writer :port

    # Creates a new configuration instance.
    #
    # @param params [Hash] configuration options
    # @option params [String] :host server hostname (default: "localhost")
    # @option params [Integer, nil] :port native endpoint port (default: 9000, or 9440 with TLS)
    # @option params [String] :database database name (default: "default")
    # @option params [String] :username authentication username (default: "")
    # @option params [String] :password authentication password (default: "")
    # @option params [Integer] :connection_timeout connection timeout in seconds (default: 5)
    # @option params [Integer] :read_timeout read timeout in seconds (default: 60)
    # @option params [Integer] :write_timeout write timeout in seconds (default: 60)
    # @option params [Integer] :pool_size connection pool size (default: 100)
    # @option params [Integer] :pool_timeout pool checkout timeout (default: 5)
    # @option params [Integer] :max_retries max retry attempts on connection errors (default: 3)
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
      ssl, fallback_port = URL_SCHEMES.fetch(uri.scheme) do
        raise ArgumentError, "unsupported ClickHouse URL scheme: #{uri.scheme.inspect}"
      end

      @ssl = ssl
      @port = uri.port || fallback_port
      @host = uri.host
      @database = uri.path.delete_prefix("/")
      @username = uri.user
      @password = uri.password
    end

    private

    def default_port
      ssl ? 9440 : 9000
    end
  end
end
