## Unreleased

- Improved large result decoding speed (about 1.9x faster for the 100K-row benchmark query) and reduced its allocations from 97 MB to 55 MB
- Fixed quadratic re-parsing of large uncompressed result blocks (about 5x faster for multi-megabyte String columns)
- Faster decoding of repeated `Date`/`Date32` values, `Nullable(String)`, `UUID`, and `Map` with String keys, and faster `Response#each`

## [0.4.0] - 2026-10-06

- Raised the minimum supported ClickHouse version to 23.3; connections to older servers are rejected during the handshake
- Updated vendored clickhouse-c headers to `916cbf5`, adding sparse column decoding
- Improved decimal decoding performance while preserving exact values across all decimal widths
- Fixed decoding of geometry types, including Point, Ring, Polygon, MultiPolygon, LineString, and MultiLineString
- Preserved complete UTF-8 server error messages during connection establishment

## [0.3.1] - 2026-08-19

- Fixed LZ4 compression negotiation for ClickHouse users configured with `readonly = 1`

## [0.3.0] - 2026-08-11

- Switched from HTTP to ClickHouse's native TCP protocol for faster queries and lower allocations
- Added connection pooling, LZ4/ZSTD compression, TLS, and native ClickHouse URLs
- Added native query parameters and per-query ClickHouse settings
- Added support for Ruby array query parameters
- Added opt-in `idempotent: true` query retries for transport failures on fresh pooled connections
- Added configurable capped exponential backoff with jitter between connection retries
- Improved connection timeouts, retries, fork safety, and idle connection handling
- Removed HTTP configuration; existing connections must use native ports, normally 9000 or 9440

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
