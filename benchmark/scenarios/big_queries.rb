# frozen_string_literal: true

require_relative "../benchmark_helper"
require_relative "../adapters"

BIG_QUERY = BenchmarkHelper::BIG_QUERY

puts "=" * 60
puts "SCENARIO 2: Big Query Benchmark"
puts "=" * 60
puts "Testing large result set parsing (100K rows, various types)"
puts

config = BenchmarkHelper::CONFIG
adapters = Adapters.build_all(config)

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
