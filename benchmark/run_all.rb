#!/usr/bin/env ruby
# frozen_string_literal: true

puts "=" * 70
puts "ch_connect Benchmark Suite"
puts "Comparing: ch_connect, click_house, clickhouse, click_house-client"
puts "=" * 70
puts

scenarios = {
  "Scenario 1: Small Queries" => "scenarios/small_queries.rb",
  "Scenario 2: Big Queries" => "scenarios/big_queries.rb"
}

# Parse command line arguments
selected = ARGV.empty? ? scenarios.keys : ARGV

scenarios.each do |name, path|
  next unless selected.any? { |s| name.downcase.include?(s.downcase) || path.include?(s) }

  puts "\n" + "#" * 70
  puts "# #{name}"
  puts "#" * 70
  puts

  begin
    load File.expand_path(path, __dir__)
  rescue => e
    puts "ERROR running #{name}: #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end

  puts "\n"
end

puts "=" * 70
puts "All Benchmarks Complete"
puts "=" * 70
