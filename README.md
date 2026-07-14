# ch_connect

> **Note:** This gem was previously published as `clickhouse-rb` and was renamed to `ch_connect` due to name conflicts.

Fast MRI Ruby client for ClickHouse's native TCP protocol.

## Features

- Native TCP protocol and binary result decoding
- Persistent pooled connections safe for concurrent use
- LZ4 or ZSTD block compression
- TLS with certificate verification
- Automatic retries on connection failures
- Interruptible connect, read, and write timeouts
- Common ClickHouse scalar and composite types

The native protocol avoids HTTP request/response overhead. In the current benchmark suite, a small query allocates approximately 3.2 KB / 32 Ruby objects, while a 100K-row typed query runs at approximately 8.2 iterations per second on Ruby 4.0.3. See `benchmark/` for the comparison suite and methodology.

## Installation

Add the gem to your Gemfile:

```ruby
gem "ch_connect"
```

The gem contains a native extension and currently requires MRI Ruby. LZ4 and ZSTD support are detected when the extension is built.

## Configuration

```ruby
require "ch_connect"

ChConnect.configure do |config|
  config.host = "localhost"
  config.port = 9000
  config.database = "default"
  config.username = "default"
  config.password = ""
end
```

Or use a native ClickHouse URL:

```ruby
ChConnect.configure do |config|
  config.url = "clickhouse://user:pass@localhost:9000/mydb"
end
```

Supported URL schemes:

- `clickhouse://` and `tcp://`: plaintext TCP, default port 9000
- `clickhouses://` and `tcps://`: TLS, default port 9440

```ruby
ChConnect.configure do |config|
  config.url = "clickhouses://user:pass@clickhouse.example.com:9440/mydb"
  config.ssl_ca = "/path/to/ca.crt" # optional; system roots are the default
end
```

HTTP URLs and ClickHouse's HTTP endpoint are not supported.

## Querying

```ruby
conn = ChConnect::Connection.new
response = conn.query("SELECT id, name FROM users WHERE active = true")

response.each do |row|
  puts "#{row[:id]}: #{row[:name]}"
end
```

A `Connection` owns a connection pool and is safe for concurrent use:

```ruby
conn = ChConnect::Connection.new

threads = 10.times.map do
  Thread.new { conn.query("SELECT 1") }
end
threads.each(&:join)
```

### Results

`Response` implements `Enumerable`:

```ruby
response = conn.query("SELECT id, name, created_at FROM users")

response.each { |row| puts row[:name] }
response.map { |row| row[:id] }
response.first

response.rows      # [[1, "Alice", 2024-01-01 00:00:00 UTC], ...]
response.columns   # [:id, :name, :created_at]
response.types     # [:UInt64, :String, :DateTime]
response.to_a      # [{id: 1, name: "Alice", ...}, ...]
response.summary   # {read_rows: "1", read_bytes: "42", ...}
```

`summary[:client_elapsed_ns]` is client wall-clock time for the complete query,
including pool checkout and connection establishment. Native responses do not
currently expose the HTTP transport's former server-side `elapsed_ns` metric.

### Query parameters

```ruby
response = conn.query(
  "SELECT * FROM users WHERE id = {id:UInt64}",
  params: {param_id: 123}
)
```

`nil` is encoded as the native nullable marker.
Parameter keys must use the `param_` prefix. Options such as
`max_execution_time` that older HTTP releases accepted through `params:` must
move to `settings:`; the database is configured on the connection.

### Query settings

Any ClickHouse setting can be supplied per query:

```ruby
response = conn.query(
  "SELECT * FROM big_table",
  settings: {
    max_threads: 2,
    max_result_rows: 10_000,
    result_overflow_mode: "break"
  }
)
```

## Supported data types

| ClickHouse type | Ruby type |
|-----------------|-----------|
| UInt8/16/32/64/128/256 | Integer |
| Int8/16/32/64/128/256 | Integer |
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

Unsupported types raise `ChConnect::UnsupportedTypeError` and discard the affected pooled connection.

## Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `host` | `"localhost"` | ClickHouse server host |
| `port` | `9000` | Native TCP port (`9440` when TLS is enabled before port resolution) |
| `compression` | `:lz4` | `:lz4`, `:zstd`, or `nil` |
| `ssl` | `false` | Enable TLS |
| `ssl_verify` | `true` | Verify the server certificate |
| `ssl_ca` | `nil` | CA certificate file; system roots are used by default |
| `database` | `"default"` | Database name |
| `username` | `""` | Authentication username; empty becomes `default` |
| `password` | `""` | Authentication password |
| `connection_timeout` | `5` | TCP and protocol handshake timeout in seconds |
| `read_timeout` | `60` | Maximum time without response data |
| `write_timeout` | `60` | Socket write deadline in seconds |
| `keep_alive_timeout` | `60` | Recycle pooled TCP connections after this many idle seconds; `nil` disables recycling |
| `pool_size` | `100` | Maximum pooled TCP connections |
| `pool_timeout` | `5` | Pool checkout timeout in seconds |
| `max_retries` | `3` | Connection-establishment retries; queries are never retried after sending may have begun |
| `instrumenter` | `NullInstrumenter` | Object responding to `instrument` |

## Instrumentation

```ruby
ChConnect.configure do |config|
  config.instrumenter = ActiveSupport::Notifications
end

ActiveSupport::Notifications.subscribe("query.clickhouse") do |name, start, finish, id, payload|
  puts "Query: #{payload[:sql]} took #{finish - start}s"
end
```

## Error handling

```ruby
begin
  conn.query("INVALID SQL")
rescue ChConnect::QueryError => error
  warn error.message
end

begin
  conn.query("SELECT '{}'::JSON")
rescue ChConnect::UnsupportedTypeError => error
  warn error.message
end
```

Network, timeout, pool, and protocol failures raise `ChConnect::ConnectionError`.
When migrating from the HTTP client, change port 8123/8443 to the server's
native port (normally 9000/9440) and replace `scheme` with `ssl` or a native URL.

## Development

```bash
cd ext/ch_connect_native
ruby extconf.rb
make
cp "ch_connect_native.$(ruby -rrbconfig -e 'print RbConfig::CONFIG["DLEXT"]')" ../../lib/ch_connect/
cd ../..

CLICKHOUSE_URL=clickhouse://default:password@localhost:9000/default bundle exec rspec

# Optional TLS specs
spec/support/start_tls_clickhouse.sh /tmp/ch-tls password
CH_TLS_PORT=9440 CH_TLS_CA=/tmp/ch-tls/server.crt \
  CLICKHOUSE_URL=clickhouse://default:password@localhost:9000/default bundle exec rspec

bundle exec standardrb
```

## License

MIT License
