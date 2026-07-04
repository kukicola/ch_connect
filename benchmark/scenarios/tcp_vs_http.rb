# frozen_string_literal: true

require_relative "../benchmark_helper"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "ch_connect"

SMALL_QUERY = BenchmarkHelper::SMALL_QUERY
BIG_QUERY = BenchmarkHelper::BIG_QUERY

puts "=" * 60
puts "SCENARIO: HTTP (Ruby parser) vs TCP native (C parser)"
puts "=" * 60

http_conn = BenchmarkHelper.ch_connect_connection
tcp_conn = BenchmarkHelper.ch_connect_connection(transport: :native)

# Correctness check: both transports must return identical data
[SMALL_QUERY, BIG_QUERY].each do |sql|
  http_result = http_conn.query(sql)
  tcp_result = tcp_conn.query(sql)

  raise "Column mismatch: #{http_result.columns.inspect} vs #{tcp_result.columns.inspect}" unless http_result.columns == tcp_result.columns
  raise "Type mismatch: #{http_result.types.inspect} vs #{tcp_result.types.inspect}" unless http_result.types == tcp_result.types
  raise "Row count mismatch: #{http_result.rows.size} vs #{tcp_result.rows.size}" unless http_result.rows.size == tcp_result.rows.size

  http_result.rows.each_with_index do |row, i|
    next if row == tcp_result.rows[i]
    raise "Row #{i} mismatch:\n  http: #{row.inspect}\n  tcp:  #{tcp_result.rows[i].inspect}"
  end
end
puts "Verified: identical columns, types and rows on both transports\n"

adapters_small = {
  "ch_connect http": -> { http_conn.query(SMALL_QUERY) },
  "ch_connect tcp": -> { tcp_conn.query(SMALL_QUERY) }
}

adapters_big = {
  "ch_connect http": -> { http_conn.query(BIG_QUERY).to_a },
  "ch_connect tcp": -> { tcp_conn.query(BIG_QUERY).to_a }
}

BenchmarkHelper.run_ips("Small Query (10 rows) IOPS", adapters: adapters_small)
BenchmarkHelper.run_ips("Big Query (100K rows) IOPS", adapters: adapters_big, warmup: 1, time: 3)
BenchmarkHelper.run_memory("Big Query (100K rows)", adapters: adapters_big)
