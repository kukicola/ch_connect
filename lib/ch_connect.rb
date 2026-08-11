# frozen_string_literal: true

require_relative "ch_connect/version"
require_relative "ch_connect/null_instrumenter"
require_relative "ch_connect/config"
require_relative "ch_connect/response"

# Ruby client for ClickHouse database with Native format support.
#
# @example Basic usage
#   ChConnect.configure do |config|
#     config.host = "localhost"
#     config.port = 9000
#   end
#
#   conn = ChConnect::Connection.new
#   response = conn.query("SELECT 1")
module ChConnect
  # Base error class for all ChConnect errors
  class Error < StandardError; end

  # Raised when a query fails (syntax error, unknown table, etc.)
  class QueryError < Error; end

  # Raised on network/connection failures
  class ConnectionError < Error; end

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
    yield config
  end
end

begin
  require "ch_connect/ch_connect_native"
rescue LoadError => e
  raise ChConnect::Error, "ch_connect requires the compiled native extension: #{e.message}"
end
ChConnect.private_constant :NativeClient

require_relative "ch_connect/connection"
