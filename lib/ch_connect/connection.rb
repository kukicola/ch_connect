# frozen_string_literal: true

module ChConnect
  # A single connection to ClickHouse server.
  #
  # @example
  #   conn = ChConnect::Connection.new
  #   response = conn.query("SELECT * FROM users WHERE id = 1")
  class Connection
    # @return [Config] the configuration used by this connection
    attr_reader :config

    # Creates a new connection.
    #
    # @param config [Config] configuration instance (defaults to global config)
    def initialize(config = ChConnect.config)
      @config = config
      @transport = case config.transport
      when :http
        HttpTransport.new(config)
      when :native
        TcpTransport.new(config)
      else
        raise Error, "unknown transport: #{config.transport.inspect} (use :http or :native)"
      end
    end

    # Executes a SQL query and returns the response.
    #
    # @param sql [String] SQL query to execute
    # @param options [Hash] query options
    # @option options [Hash] :params query parameters
    # @return [Response] query response with rows, columns, and metadata
    # @raise [QueryError] if the query fails
    def query(sql, options = {})
      @config.instrumenter.instrument("query.clickhouse", {sql: sql}) do
        @transport.query(sql, options)
      end
    end
  end
end
