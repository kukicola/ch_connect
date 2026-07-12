## Unreleased

- Added experimental native TCP protocol transport (`config.transport = :native`) backed by a C extension over vendored [clickhouse-c](https://github.com/ClickHouse/clickhouse-c); the extension is an ioless protocol state machine + block decoder while all socket I/O lives in Ruby (~2x faster large queries, ~35% faster small queries, ~4.5x multi-threaded throughput, ~20% less allocation)
- Native transport features: connection pooling via `connection_pool`, LZ4/ZSTD block compression (`config.compression`, default `:lz4`), TLS via the openssl stdlib (`config.ssl`, `config.ssl_verify`, `config.ssl_ca`), connect/read/write timeouts, natively interruptible Ruby socket I/O
- Native URL schemes (`clickhouse://`, `clickhouses://`, `tcp://`, `tcps://`) configure transport, TCP port, TLS, credentials and database
- Added per-query ClickHouse settings on both transports: `conn.query(sql, settings: {max_threads: 1})`
- New config options: `transport`, `compression`, `ssl`, `ssl_verify`, `ssl_ca`; `port` selects the active HTTP or native endpoint
- New dependency: `connection_pool` (~> 2.4)
- Connection-level HTTP failures (timeouts, refused connections) now raise `ChConnect::ConnectionError` instead of `ChConnect::QueryError`; `QueryError` remains for server-side query errors

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
