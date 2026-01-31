# frozen_string_literal: true

require_relative "ch_connect/version"
require_relative "ch_connect/null_instrumenter"
require_relative "ch_connect/config"
require_relative "ch_connect/transport_result"
require_relative "ch_connect/http_transport"
require_relative "ch_connect/connection"
require_relative "ch_connect/response"
require_relative "ch_connect/body_reader"
require_relative "ch_connect/native_format_parser"

# Ruby client for ClickHouse database with Native format support.
#
# @example Basic usage
#   ChConnect.configure do |config|
#     config.host = "localhost"
#     config.port = 8123
#   end
#
#   conn = ChConnect::Connection.new
#   response = conn.query("SELECT 1")
#
# @example Using connection pool
#   pool = ChConnect::Pool.new
#   response = pool.query("SELECT * FROM users")
module ChConnect
  # Base error class for all ChConnect errors
  class Error < StandardError; end

  # Raised when a query fails (syntax error, unknown table, etc.)
  class QueryError < Error; end

  # Raised when encountering an unsupported ClickHouse data type
  class UnsupportedTypeError < Error; end

  # Returns the global configuration instance.
  #
  # @return [Config] the configuration instance
  def self.config
    @config ||= Config.new
  end

  # Yields the global configuration for modification.
  #
  # @yield [Config] the configuration instance
  # @return [void]
  def self.configure
    yield(config) if block_given?
  end
end
