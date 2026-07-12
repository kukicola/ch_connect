# ch_connect

> **Note:** This gem was previously published as `clickhouse-rb` and has been renamed to `ch_connect` due to name conflicts.

Fast Ruby client for ClickHouse database using the Native binary format for efficient data transfer.

## Features

- Native binary format parsing (faster than JSON/TSV)
- Persistent HTTP connections with built-in connection pooling
- Automatic retries on connection errors
- Thread-safe concurrent access
- Supports all common ClickHouse data types

## Benchmarks

Compared against other Ruby ClickHouse gems ([click_house](https://github.com/shlima/click_house), [clickhouse](https://github.com/archan937/clickhouse), [click_house-client](https://gitlab.com/gitlab-org/ruby/gems/clickhouse-client)) on Ruby 4.0.3. `ch_connect` is measured on both transports; TCP runs with LZ4 compression (the default).

**Speed (iterations/second, higher is better):**

| Scenario | ch_connect (TCP) | ch_connect (HTTP) | click_house | clickhouse | click_house-client |
|----------|-----------------|-------------------|-------------|------------|--------------------|
| Small queries (10 rows) | **962 i/s** | 709 i/s | 363 i/s (2.7x slower) | 317 i/s (3.0x slower) | 372 i/s (2.6x slower) |
| Large queries (100K rows) | **8.2 i/s** | 4.1 i/s | 1.1 i/s (7.2x slower) | 0.6 i/s (14.1x slower) | 1.5 i/s (5.3x slower) |

**Multi-threaded throughput (10K-row query, total queries/second):**

| Threads | ch_connect (TCP) | ch_connect (HTTP) | click_house | clickhouse | click_house-client |
|---------|-----------------|-------------------|-------------|------------|--------------------|
| 1 | **292 q/s** | 76 q/s | 69 q/s | 117 q/s | 48 q/s |
| 4 | **598 q/s** | 120 q/s | 162 q/s | 319 q/s | 82 q/s |
| 8 | **606 q/s** | 122 q/s | 158 q/s | 321 q/s | 80 q/s |

**Memory (large query, allocated, lower is better):**

| Gem | Allocated |
|-----|-----------|
| ch_connect (TCP) | **97 MB** |
| ch_connect (HTTP) | 130 MB |
| click_house | 198 MB |
| click_house-client | 210 MB |
| clickhouse | 436 MB |

A small query allocates just **3.2 KB / 32 Ruby objects** over TCP (vs 46–95 KB / 500–1000 objects for the HTTP-based gems) — the native protocol has no HTTP request/response machinery.

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

URL schemes select the transport, port and TLS mode as well as credentials and
database. `http://`/`https://` select HTTP, `clickhouse://`/`tcp://` select
plaintext native TCP, and `clickhouses://`/`tcps://` select native TCP with TLS.

```ruby
ChConnect.configure do |config|
  config.url = "clickhouses://user:pass@clickhouse.example.com:9440/mydb"
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

Both transports pool connections, making a `Connection` safe for concurrent use:

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

### Query Settings

Any [ClickHouse setting](https://clickhouse.com/docs/operations/settings/settings) can be applied per query on both transports:

```ruby
response = conn.query(
  "SELECT * FROM big_table",
  settings: { max_threads: 2, max_result_rows: 10_000, result_overflow_mode: "break" }
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

## Native TCP Transport (experimental)

Besides the default HTTP transport, ch_connect ships a native TCP protocol
transport backed by a C extension (vendored
[clickhouse-c](https://github.com/ClickHouse/clickhouse-c)). Result blocks are
parsed in C, roughly doubling large-result throughput and tripling
multi-threaded throughput:

```ruby
ChConnect.configure do |config|
  config.transport = :native
  config.port = 9000            # native protocol port (9440 for TLS)
  config.compression = :lz4     # :lz4 (default), :zstd or nil
  # TLS:
  # config.ssl = true
  # config.ssl_verify = true    # default; verifies against system CA store
  # config.ssl_ca = "/path/to/ca.crt"
end
```

The C extension is a pure protocol state machine and block decoder — all
socket I/O, TLS, and timeouts are plain Ruby IO, so queries are
GVL-friendly and interruptible like any Ruby socket code.

Details and caveats:

- MRI only; the extension compiles at gem install. LZ4/ZSTD support is
  detected at build time (`liblz4`, `libzstd`); TLS uses the openssl
  stdlib and is always available.
- Each `Connection` keeps a pool (`pool_size`) of TCP connections.
- `read_timeout` bounds time-without-data, like the HTTP transport. `Ctrl-C`
  and `Thread#kill` interrupt in-flight queries cleanly; `write_timeout`
  bounds native socket writes.
- Not supported (yet): INSERT streaming optimizations, JRuby/TruffleRuby
  (`transport: :native` raises; use the default `transport: :http`).

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `transport` | `:http` | `:http` or `:native` (TCP protocol via C extension) |
| `scheme` | `"http"` | URL scheme (http/https) |
| `host` | `"localhost"` | ClickHouse server host |
| `port` | `8123` / `9000` | Active HTTP/native protocol port (TLS defaults: 8443/9440) |
| `compression` | `:lz4` | Block compression for `:native`: `:lz4`, `:zstd` or `nil` |
| `ssl` | `false` | Use TLS for the `:native` transport |
| `ssl_verify` | `true` | Verify server certificate when `ssl` is enabled |
| `ssl_ca` | `nil` | CA certificate file for TLS verification (default: system store) |
| `database` | `"default"` | Database name |
| `username` | `""` | Authentication username |
| `password` | `""` | Authentication password |
| `connection_timeout` | `5` | Connection timeout in seconds |
| `read_timeout` | `60` | Read timeout in seconds |
| `write_timeout` | `60` | Write timeout in seconds |
| `keep_alive_timeout` | `8` | Idle persistent connection timeout in seconds (HTTP only) |
| `pool_size` | `100` | Connection pool size |
| `pool_timeout` | `5` | Pool checkout timeout in seconds |
| `max_retries` | `3` | Max retry attempts on connection errors (0 to disable) |
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
# Compile the native extension
cd ext/ch_connect_native && ruby extconf.rb && make && \
  cp "ch_connect_native.$(ruby -rrbconfig -e 'print RbConfig::CONFIG["DLEXT"]')" ../../lib/ch_connect/ && cd ../..

# Run tests over HTTP (requires ClickHouse)
CLICKHOUSE_URL=http://default:password@localhost:8123/default bundle exec rspec

# Run tests over the native TCP transport (requires port 9000)
CH_TRANSPORT=native CLICKHOUSE_URL=http://default:password@localhost:8123/default bundle exec rspec

# TLS specs (optional): start a TLS-enabled ClickHouse, then add the env vars
spec/support/start_tls_clickhouse.sh /tmp/ch-tls password
CH_TRANSPORT=native CH_TLS_PORT=9440 CH_TLS_CA=/tmp/ch-tls/server.crt \
  CLICKHOUSE_URL=http://default:password@localhost:8123/default bundle exec rspec

# Run linter
bundle exec standardrb
```

## License

MIT License
