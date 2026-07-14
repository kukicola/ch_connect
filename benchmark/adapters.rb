# frozen_string_literal: true

require "date"
require "ch_connect"
require "click_house"
require "clickhouse"
require "click_house/client"
require "net/http"
require "uri"

module Adapters
  # Adapter for ch_connect's native TCP protocol.
  class ChConnectAdapter
    attr_reader :connection

    def initialize(config = {})
      ch_config = ChConnect::Config.new(
        host: config[:host] || "localhost",
        username: config[:username] || "default",
        password: config[:password] || "default"
      )
      @connection = ChConnect::Connection.new(ch_config)
    end

    def name = :ch_connect
    def execute(sql) = @connection.query(sql)
    def result_to_array(result) = result.to_a
    def result_row_count(result) = result.rows.size
  end

  # Adapter for click_house gem (shlima) - JSON format, Faraday
  class ClickHouseAdapter
    def initialize(config = {})
      ClickHouse.config do |c|
        c.url = "http://#{config[:host] || "localhost"}:#{config[:port] || 8123}"
        c.username = config[:username] || "default"
        c.password = config[:password] || "default"
      end
    end

    def name = :click_house
    def execute(sql) = ClickHouse.connection.select_all(sql)
    def result_to_array(result) = result.to_a
    def result_row_count(result) = result.to_a.size
  end

  # Adapter for clickhouse gem (archan937) - JSONCompact format, Faraday
  class ClickhouseAdapter
    def initialize(config = {})
      Clickhouse.establish_connection(
        host: config[:host] || "localhost",
        port: config[:port] || 8123,
        username: config[:username] || "default",
        password: config[:password] || "default"
      )
    end

    def name = :clickhouse
    def execute(sql) = Clickhouse.connection.query(sql)
    def result_to_array(result) = result.to_a
    def result_row_count(result) = result.to_a.size
  end

  # Adapter for click_house-client gem (GitLab) - JSON format, Net::HTTP
  class GitlabAdapter
    def initialize(config = {})
      host = config[:host] || "localhost"
      port = config[:port] || 8123
      username = config[:username] || "default"
      password = config[:password] || "default"

      @config = ClickHouse::Client::Configuration.new
      @config.register_database(
        :main,
        database: "default",
        url: "http://#{host}:#{port}",
        username: username,
        password: password
      )

      @config.http_post_proc = ->(url, headers, body) do
        uri = URI.parse(url)
        unless body.is_a?(IO)
          uri.query = [uri.query, URI.encode_www_form(body.except("query"))].compact.join("&")
        end

        request = Net::HTTP::Post.new(uri)
        headers.each { |header, value| request[header] = value }
        request["Content-type"] = "application/x-www-form-urlencoded"
        request.body = body.is_a?(IO) ? nil : body["query"]
        request.body_stream = body if body.is_a?(IO)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end

        ClickHouse::Client::Response.new(response.body, response.code.to_i, response.each_header.to_h)
      end

      @config.json_parser = JSON
      @config.logger = Logger.new(File::NULL)
    end

    def name = :gitlab
    def execute(sql) = ClickHouse::Client.select(sql, :main, @config)
    def result_to_array(result) = result
    def result_row_count(result) = result.size
  end

  def self.build_all(config)
    {
      ch_connect: ChConnectAdapter.new(config),
      click_house: ClickHouseAdapter.new(config),
      clickhouse: ClickhouseAdapter.new(config),
      gitlab: GitlabAdapter.new(config)
    }
  end
end
