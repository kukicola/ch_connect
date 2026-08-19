## Unreleased

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
