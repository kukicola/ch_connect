# ch_connect

> **Note:** This gem was previously published as `clickhouse-rb` and has been renamed to `ch_connect` due to name conflicts.

Fast Ruby client for ClickHouse database using the Native binary format for efficient data transfer.

## Features

- Native binary format parsing (faster than JSON/TSV)
- Persistent HTTP connections with built-in connection pooling
- Thread-safe concurrent access
- Supports all common ClickHouse data types

## Benchmarks

Compared against other Ruby ClickHouse gems ([click_house](https://github.com/shlima/click_house), [clickhouse](https://github.com/archan937/clickhouse), [click_house-client](https://gitlab.com/gitlab-org/ruby/gems/clickhouse-client)) on Ruby 3.4.3:

**Speed (iterations/second, higher is better):**

| Scenario | ch_connect | click_house | clickhouse | click_house-client |
|----------|------------|-------------|------------|--------------------|
| Small queries (10 rows) | **680 i/s** | 342 i/s (2.0x slower) | 293 i/s (2.3x slower) | 346 i/s (2.0x slower) |
| Large queries (100K rows) | **3.5 i/s** | 1.1 i/s (3.3x slower) | 0.5 i/s (6.9x slower) | 1.6 i/s (2.2x slower) |

**Memory (large query, lower is better):**

| Gem | Allocated |
|-----|-----------|
| ch_connect | **130 MB** |
| click_house | 205 MB (1.6x more) |
| clickhouse | 483 MB (3.7x more) |
| click_house-client | 210 MB (1.6x more) |

See `benchmark/` directory for full benchmark suite and methodology.

## Installation

Add to your Gemfile:

```ruby
gem "ch_connect"
```

Then run:

```bash
bundle install
```

## Usage

### Configuration

```ruby
require "ch_connect"

ChConnect.configure do |config|
  config.host = "localhost"
  config.port = 8123
  config.database = "default"
  config.username = "default"
  config.password = ""
end
```

Or configure via URL:

```ruby
ChConnect.configure do |config|
  config.url = "http://user:pass@localhost:8123/mydb"
end
```

### Single Connection

```ruby
conn = ChConnect::Connection.new
response = conn.query("SELECT id, name FROM users WHERE active = true")

response.each do |row|
  puts "#{row[:id]}: #{row[:name]}"
end
```

### Thread-Safe Usage

Connections use httpx's built-in connection pooling, making them safe for concurrent use:

```ruby
conn = ChConnect::Connection.new

threads = 10.times.map do
  Thread.new { conn.query("SELECT 1") }
end
threads.each(&:join)
```

Pool settings are configured globally:

```ruby
ChConnect.configure do |config|
  config.pool_size = 10
  config.pool_timeout = 5
end
```

### Working with Results

Response objects implement `Enumerable`, allowing direct iteration:

```ruby
response = conn.query("SELECT id, name, created_at FROM users")

# Iterate over rows as hashes with symbol keys
response.each { |row| puts row[:name] }

# Use any Enumerable method
response.map { |row| row[:id] }
response.select { |row| row[:id] > 10 }
response.first   # => {id: 1, name: "Alice", created_at: 2024-01-01 00:00:00 UTC}

# Access raw rows (arrays)
response.rows      # => [[1, "Alice", 2024-01-01 00:00:00 UTC], ...]
response.columns   # => [:id, :name, :created_at]
response.types     # => [:UInt64, :String, :DateTime]

# Convert to array of hashes
response.to_a      # => [{id: 1, name: "Alice", ...}, ...]

# Query summary from ClickHouse (symbol keys)
response.summary   # => {read_rows: "1", read_bytes: "42", ...}
```

### Query Parameters

```ruby
response = conn.query(
  "SELECT * FROM users WHERE id = {id:UInt64}",
  params: { param_id: 123 }
)
```

## Supported Data Types

| ClickHouse Type | Ruby Type |
|-----------------|-----------|
| UInt8/16/32/64 | Integer |
| UInt128/256 | Integer |
| Int8/16/32/64 | Integer |
| Int128/256 | Integer |
| Float32/64 | Float |
| Decimal | BigDecimal |
| Bool | TrueClass/FalseClass |
| String, FixedString | String |
| Date, Date32 | Date |
| DateTime, DateTime64 | Time |
| UUID | String |
| IPv4, IPv6 | IPAddr |
| Enum8, Enum16 | Integer |
| Array | Array |
| Tuple | Array |
| Map | Hash |
| Nullable | nil or inner type |
| LowCardinality | inner type |

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `scheme` | `"http"` | URL scheme (http/https) |
| `host` | `"localhost"` | ClickHouse server host |
| `port` | `8123` | ClickHouse HTTP port |
| `database` | `"default"` | Database name |
| `username` | `""` | Authentication username |
| `password` | `""` | Authentication password |
| `connection_timeout` | `5` | Connection timeout in seconds |
| `read_timeout` | `60` | Read timeout in seconds |
| `write_timeout` | `60` | Write timeout in seconds |
| `pool_size` | `100` | Connection pool size |
| `pool_timeout` | `5` | Pool checkout timeout in seconds |
| `instrumenter` | `NullInstrumenter` | Instrumenter for query instrumentation |

## Instrumentation

You can instrument queries by providing an instrumenter that responds to `#instrument`:

```ruby
ChConnect.configure do |config|
  config.instrumenter = ActiveSupport::Notifications
end

# Subscribe to events
ActiveSupport::Notifications.subscribe("query.clickhouse") do |name, start, finish, id, payload|
  puts "Query: #{payload[:sql]} took #{finish - start}s"
end
```

The instrumenter receives event name `"query.clickhouse"` and payload `{sql: "..."}`.

## Error Handling

```ruby
begin
  conn.query("INVALID SQL")
rescue ChConnect::QueryError => e
  puts "Query failed: #{e.message}"
end

# Unsupported types raise an exception
begin
  conn.query("SELECT '{}'::JSON")
rescue ChConnect::UnsupportedTypeError => e
  puts "Unsupported type: #{e.message}"
end
```

## Development

```bash
# Run tests (requires ClickHouse)
CLICKHOUSE_URL=http://default:password@localhost:8123/default bundle exec rspec

# Run linter
bundle exec standardrb
```

## License

MIT License
