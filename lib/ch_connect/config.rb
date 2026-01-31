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
      scheme: "http",
      host: "localhost",
      port: 8123,
      database: "default",
      username: "",
      password: "",
      connection_timeout: 5,
      read_timeout: 60,
      write_timeout: 60,
      pool_size: 100,
      pool_timeout: 5,
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
    # @return [Integer] Connection pool size
    # @return [Integer] Pool checkout timeout in seconds
    # @return [#instrument] Instrumenter for query instrumentation
    attr_accessor :scheme, :host, :port, :database, :username, :password, :connection_timeout, :read_timeout, :write_timeout, :pool_size, :pool_timeout, :instrumenter

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
    # @option params [Integer] :pool_size connection pool size (default: 100)
    # @option params [Integer] :pool_timeout pool checkout timeout (default: 5)
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
      @scheme = uri.scheme
      @host = uri.host
      @port = uri.port
      @database = uri.path.delete_prefix("/")
      @username = uri.user
      @password = uri.password
    end
  end
end
