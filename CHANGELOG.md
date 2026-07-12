## Unreleased

- Switched all connections to ClickHouse's native TCP protocol and removed the HTTP/HTTPX transport
- Added a C extension over vendored [clickhouse-c](https://github.com/ClickHouse/clickhouse-c); it provides an ioless protocol state machine and block decoder while socket I/O remains in Ruby
- Added connection pooling via `connection_pool`, LZ4/ZSTD block compression (`config.compression`, default `:lz4`), TLS (`config.ssl`, `config.ssl_verify`, `config.ssl_ca`), connect/read/write timeouts and interruptible socket I/O
- Native URL schemes (`clickhouse://`, `clickhouses://`, `tcp://`, `tcps://`) configure TCP port, TLS, credentials and database
- Added per-query ClickHouse settings: `conn.query(sql, settings: {max_threads: 1})`
- New config options: `compression`, `ssl`, `ssl_verify`, `ssl_ca`
- New dependency: `connection_pool` (~> 2.4)
- Connection failures raise `ChConnect::ConnectionError`; `QueryError` remains for server-side query errors

## [0.2.2] - 2026-05-06

- Added configurable `keep_alive_timeout` for idle persistent connections (default: 8s) ([#7](https://github.com/kukicola/ch_connect/pull/7))

## [0.2.1] - 2026-02-08

- Added automatic retries on connection errors with configurable `max_retries` (default: 3) ([#6](https://github.com/kukicola/ch_connect/pull/6))

## [0.2.0] - 2026-01-31

- Added benchmark suite comparing against other ClickHouse Ruby gems ([#5](https://github.com/kukicola/ch_connect/pull/5))
- Optimized BodyReader with chunked buffering for better memory efficiency ([#5](https://github.com/kukicola/ch_connect/pull/5))
- Optimized NativeFormatParser with transpose-based row building ([#5](https://github.com/kukicola/ch_connect/pull/5))

## [0.1.0] - 2026-01-31

- Initial release
