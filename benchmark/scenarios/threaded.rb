# frozen_string_literal: true

require_relative "../benchmark_helper"
require_relative "../adapters"

# Multi-threaded throughput: total queries/second across N worker threads.
# ch_connect HTTP uses the HTTPX pool; ch_connect TCP uses its native
# connection pool; the other gems use their default connection handling.

THREAD_COUNTS = [1, 4, 8]
DURATION = 4 # seconds per measurement

THREADED_QUERY = <<~SQL.strip
  SELECT
    number AS id,
    toString(number) AS s,
    toFloat64(number / 7.0) AS f,
    toDateTime('2024-01-01') + number AS dt
  FROM system.numbers
  LIMIT 10000
SQL

def run_threaded(adapter, threads:, duration:)
  stop = false
  error = nil
  counts = Array.new(threads, 0)

  workers = threads.times.map do |i|
    Thread.new do
      until stop
        adapter.execute(THREADED_QUERY)
        counts[i] += 1
      end
    rescue => e
      error ||= e
    end
  end

  sleep duration
  stop = true
  workers.each(&:join)

  [counts.sum / duration.to_f, error]
end

puts "=" * 76
puts "SCENARIO 3: Threaded throughput (4 col x 10K rows, #{DURATION}s per point)"
puts "=" * 76

config = BenchmarkHelper::CONFIG
adapters = {
  ch_connect: Adapters::ChConnectAdapter.new(config),
  ch_connect_tcp: Adapters::ChConnectTcpAdapter.new(config),
  click_house: Adapters::ClickHouseAdapter.new(config),
  clickhouse: Adapters::ClickhouseAdapter.new(config),
  gitlab: Adapters::GitlabAdapter.new(config)
}

# warmup / sanity
adapters.each_value { |a| a.execute(THREADED_QUERY) }

header = "threads   " + adapters.keys.map { |n| format("%18s", n) }.join
puts header
puts "-" * header.length

THREAD_COUNTS.each do |n|
  cells = adapters.map do |_name, adapter|
    qps, error = run_threaded(adapter, threads: n, duration: DURATION)
    error ? "            FAILED" : format("%14.1f q/s", qps)
  end
  puts format("%-10d", n) + cells.join
end
