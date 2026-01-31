# frozen_string_literal: true

require_relative "../benchmark_helper"
require_relative "../adapters"

BIG_QUERY = <<~SQL.strip
  SELECT
    number AS id,
    toUInt8(number % 256) AS uint8_col,
    toUInt32(number) AS uint32_col,
    toFloat64(number / 1000.0) AS float64_col,
    toString(number) AS string_col,
    toDate('2024-01-01') + number AS date_col,
    toDateTime('2024-01-01') + number AS datetime_col,
    [number, number+1, number+2] AS array_col
  FROM system.numbers
  LIMIT 100000
SQL

puts "=" * 60
puts "SCENARIO 2: Big Query Benchmark"
puts "=" * 60
puts "Testing large result set parsing (100K rows, various types)"
puts

config = BenchmarkHelper::CONFIG
adapters = {
  ch_connect: Adapters::ChConnectAdapter.new(config),
  click_house: Adapters::ClickHouseAdapter.new(config),
  clickhouse: Adapters::ClickhouseAdapter.new(config),
  gitlab: Adapters::GitlabAdapter.new(config)
}

BenchmarkHelper.verify_results(adapters, BIG_QUERY)

# Force full materialization with result_to_array to ensure fair comparison
BenchmarkHelper.run_ips(
  "Big Query IOPS",
  adapters: adapters.transform_values { |adapter| -> { adapter.result_to_array(adapter.execute(BIG_QUERY)) } },
  warmup: 1,
  time: 3
)

BenchmarkHelper.run_memory(
  "Big Query",
  adapters: adapters.transform_values { |adapter| -> { adapter.result_to_array(adapter.execute(BIG_QUERY)) } }
)

puts "\n" + "=" * 60
puts "Big Query Benchmark Complete"
puts "=" * 60
