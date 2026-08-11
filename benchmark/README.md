# ch_connect Benchmark Suite

Benchmark suite comparing `ch_connect` against other ClickHouse Ruby gems.

## Compared Gems

| Gem | Format | Transport | Repository |
|-----|--------|-----------|------------|
| ch_connect | Native + LZ4 | Native TCP protocol (C extension) | This gem |
| click_house | JSON | HTTP (Faraday) | [shlima/click_house](https://github.com/shlima/click_house) |
| clickhouse | JSONCompact | HTTP (Faraday) | [archan937/clickhouse](https://github.com/archan937/clickhouse) |
| click_house-client | JSON | HTTP (Net::HTTP) | [GitLab](https://gitlab.com/gitlab-org/ruby/gems/clickhouse-client) |

## Prerequisites

- Ruby 3.2+
- ClickHouse server on `localhost:9000` (native TCP) and `localhost:8123` (HTTP competitors)
- Credentials `default`/`default`
- The compiled native extension (`cd ext/ch_connect_native && ruby extconf.rb && make && cp ch_connect_native.$(ruby -rrbconfig -e 'print RbConfig::CONFIG["DLEXT"]') ../../lib/ch_connect/`)

## Setup

```bash
cd benchmark
bundle install
```

## Running Benchmarks

```bash
# Run all scenarios
bundle exec ruby run_all.rb

# Run with YJIT
bundle exec ruby --yjit run_all.rb

# Run specific scenario
bundle exec ruby scenarios/small_queries.rb
bundle exec ruby scenarios/big_queries.rb
bundle exec ruby scenarios/threaded.rb
```

## Scenarios

### Scenario 1: Small Query
Tests connection overhead and small result parsing.

### Scenario 2: Big Query
Tests parsing performance with 100K rows and various data types.

### Scenario 3: Threaded
Tests total throughput across 1/4/8 worker threads (10K-row query).

## Output

Each benchmark reports:
- **IOPS**: Iterations per second
- **Memory**: Allocated/retained memory and object counts
