# Vendored: clickhouse-c

- Source: https://github.com/ClickHouse/clickhouse-c
- Commit: 916cbf5ff41a218978bc073bca10f5b609a00081 (updated 2026-10-05)
- License: Apache-2.0 (see LICENSE)

The native client requires ClickHouse 23.3 or newer and advertises protocol
revision 54465, including sparse column serialization support.

Only the headers the extension includes are vendored: `clickhouse.h`,
`clickhouse-compression.h`, `clickhouse-client.h`, `clickhouse-async.h`
(plus LICENSE). Upstream's tests, docs, tools, and the `clickhouse-posix-io.h`
/ `clickhouse-openssl.h` I/O backends are not shipped — the extension is
ioless (Ruby owns the socket and TLS).

## Local patches

- `clickhouse.h` — `chc__col_read_tuple`: ClickHouse serializes the
  empty `Tuple()` as one UInt8 (zero) per row (ClickHouse/ClickHouse#55061);
  upstream reads nothing and desyncs the stream. Marked with
  `LOCAL PATCH (ch_connect)`. Should be upstreamed.

## Updating

Clone the pinned or newer commit, copy the four headers + LICENSE over this
directory, re-apply the patches above (or drop them once fixed upstream), and
run the full spec suite with `CH_TRANSPORT=native`.
