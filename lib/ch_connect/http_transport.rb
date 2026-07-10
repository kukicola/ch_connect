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
        .plugin(:retries, max_retries: config.max_retries, retry_change_requests: true)
        .with(
          timeout: {
            connect_timeout: config.connection_timeout,
            read_timeout: config.read_timeout,
            write_timeout: config.write_timeout,
            keep_alive_timeout: config.keep_alive_timeout
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

    # Executes a SQL query via HTTP and parses the Native format response.
    #
    # @param sql [String] SQL query to execute
    # @param options [Hash] query options
    # @option options [Hash] :params query parameters
    # @option options [Hash] :settings per-query ClickHouse settings (sent as URL parameters)
    # @return [Response] fully parsed response
    # @raise [QueryError] if the query fails
    def query(sql, options = {})
      query_params = {database: @config.database}
      query_params.merge!(options[:settings]) if options[:settings]
      query_params.merge!(format_params(options[:params])) if options[:params]
      response = @http_client.post(@base_url, params: query_params, body: sql, headers: @default_headers)

      # ErrorResponse = no HTTP exchange happened (connect/timeout failures);
      # an HTTP error status is a server-side query error instead
      raise ConnectionError, response.error.message if response.is_a?(HTTPX::ErrorResponse)

      # status check must come first: error responses (e.g. auth failures)
      # may not carry the x-clickhouse-summary header
      raise QueryError, response.body.to_s unless response.status == 200

      summary = JSON.parse(response.headers["x-clickhouse-summary"], symbolize_names: true)

      NativeFormatParser.new(response.body).parse.with(summary: summary)
    end

    private

    # HTTP query parameters use ClickHouse's escaped-text representation,
    # where \N is the NULL marker. Native TCP wraps and escapes that marker
    # for Field::restoreFromDump instead.
    def format_params(params)
      params.to_h { |key, value| [key, value.nil? ? "\\N" : value] }
    end
  end
end
