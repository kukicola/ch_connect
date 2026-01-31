# frozen_string_literal: true

require "httpx"
require "json"

module ChConnect
  # HTTP transport layer for ClickHouse communication.
  # @api private
  class HttpTransport
    # Creates a new HTTP transport.
    #
    # @param config [Config] configuration instance
    def initialize(config)
      @config = config
      @base_url = "#{config.scheme}://#{config.host}:#{config.port}"
      @http_client = HTTPX.plugin(:persistent, close_on_fork: true)
        .with(
          timeout: {
            connect_timeout: config.connection_timeout,
            read_timeout: config.read_timeout,
            write_timeout: config.write_timeout
          },
          pool_options: {
            max_connections_per_origin: config.pool_size,
            pool_timeout: config.pool_timeout
          }
        )

      @default_headers = {
        "Accept-Encoding" => "gzip",
        "X-ClickHouse-User" => config.username,
        "X-ClickHouse-Key" => config.password,
        "X-ClickHouse-Format" => "Native"
      }
    end

    # Executes a SQL query via HTTP.
    #
    # @param sql [String] SQL query to execute
    # @param options [Hash] query options
    # @option options [Hash] :params query parameters
    # @return [TransportResult] result containing body and summary
    # @raise [QueryError] if the query fails
    def execute(sql, options = {})
      query_params = {database: @config.database}.merge(options[:params] || {})
      response = @http_client.post(@base_url, params: query_params, body: sql, headers: @default_headers)

      raise QueryError, response.error.message if response.error

      summary = JSON.parse(response.headers["x-clickhouse-summary"], symbolize_names: true)

      raise QueryError, response.body.to_s unless response.status == 200

      TransportResult.new(body: response.body, summary: summary)
    end
  end
end
