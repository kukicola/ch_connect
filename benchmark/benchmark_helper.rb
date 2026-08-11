# frozen_string_literal: true

require "benchmark/ips"
require "memory_profiler"

module BenchmarkHelper
  # Common configuration
  CONFIG = {
    host: "localhost",
    port: 8123,
    username: "default",
    password: "default"
  }.freeze

  # Shared scenario queries
  SMALL_QUERY = "SELECT number FROM system.numbers LIMIT 10"

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

  # Run benchmark-ips comparison
  def self.run_ips(title, adapters:, warmup: 2, time: 5)
    puts "\n" + "=" * 60
    puts title
    puts "=" * 60

    Benchmark.ips do |x|
      x.config(warmup: warmup, time: time)

      adapters.each do |name, block|
        x.report(name.to_s, &block)
      end

      x.compare!
    end
  end

  # Run memory profiler for each adapter
  def self.run_memory(title, adapters:)
    puts "\n" + "=" * 60
    puts "Memory: #{title}"
    puts "=" * 60

    adapters.each do |name, block|
      puts "\n--- #{name} ---"
      report = MemoryProfiler.report { block.call }
      puts "Total allocated: #{format_bytes(report.total_allocated_memsize)}"
      puts "Total retained:  #{format_bytes(report.total_retained_memsize)}"
      puts "Objects allocated: #{report.total_allocated}"
      puts "Objects retained:  #{report.total_retained}"
    end
  end

  # Format bytes for human-readable output
  def self.format_bytes(bytes)
    if bytes >= 1024 * 1024
      "#{(bytes / (1024.0 * 1024)).round(2)} MB"
    elsif bytes >= 1024
      "#{(bytes / 1024.0).round(2)} KB"
    else
      "#{bytes} B"
    end
  end

  # Verify adapters return same row count
  def self.verify_results(adapters, query)
    counts = {}
    adapters.each do |name, adapter|
      result = adapter.execute(query)
      counts[name] = adapter.result_row_count(result)
    end

    if counts.values.uniq.size > 1
      puts "WARNING: Row counts differ: #{counts.inspect}"
    else
      puts "Verified: All adapters returned #{counts.values.first} rows"
    end
  end
end
