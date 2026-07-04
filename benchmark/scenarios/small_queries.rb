# frozen_string_literal: true

require_relative "../benchmark_helper"
require_relative "../adapters"

SMALL_QUERY = BenchmarkHelper::SMALL_QUERY

puts "=" * 60
puts "SCENARIO 1: Small Query Benchmark"
puts "=" * 60
puts "Testing connection overhead and small result parsing"
puts "SQL: #{SMALL_QUERY}"
puts

config = BenchmarkHelper::CONFIG
adapters = {
  ch_connect: Adapters::ChConnectAdapter.new(config),
  ch_connect_tcp: Adapters::ChConnectTcpAdapter.new(config),
  click_house: Adapters::ClickHouseAdapter.new(config),
  clickhouse: Adapters::ClickhouseAdapter.new(config),
  gitlab: Adapters::GitlabAdapter.new(config)
}

BenchmarkHelper.verify_results(adapters, SMALL_QUERY)

BenchmarkHelper.run_ips(
  "Small Query IOPS",
  adapters: adapters.transform_values { |adapter| -> { adapter.execute(SMALL_QUERY) } }
)

BenchmarkHelper.run_memory(
  "Small Query",
  adapters: adapters.transform_values { |adapter| -> { adapter.execute(SMALL_QUERY) } }
)

puts "\n" + "=" * 60
puts "Small Query Benchmark Complete"
puts "=" * 60
