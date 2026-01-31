# ch_connect Benchmark Suite

Benchmark suite comparing `ch_connect` against other ClickHouse Ruby gems.

## Compared Gems

| Gem | Format | HTTP Client | Repository |
|-----|--------|-------------|------------|
| ch_connect | Native | HTTPX | This gem |
| click_house | JSON | Faraday | [shlima/click_house](https://github.com/shlima/click_house) |
| clickhouse | JSONCompact | Faraday | [archan937/clickhouse](https://github.com/archan937/clickhouse) |
| click_house-client | JSON | Net::HTTP | [GitLab](https://gitlab.com/gitlab-org/ruby/gems/clickhouse-client) |

## Prerequisites

- Ruby 3.0+
- ClickHouse server running on `localhost:8123`
- Default credentials (`default`/`default`)

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
```

## Scenarios

### Scenario 1: Small Query
Tests connection overhead and small result parsing.

### Scenario 2: Big Query
Tests parsing performance with 100K rows and various data types.

## Output

Each benchmark reports:
- **IOPS**: Iterations per second
- **Memory**: Allocated/retained memory and object counts
