# Vendored: clickhouse-c

- Source: https://github.com/ClickHouse/clickhouse-c
- Commit: b7a6fbb14945a31a5c0b276ef27998c82982e274 (updated 2026-10-07;
  upstream commit, not a release/tag)
- License: Apache-2.0 (see LICENSE)

Only the headers the extension includes are vendored: `clickhouse.h`,
`clickhouse-compression.h`, `clickhouse-client.h`, `clickhouse-async.h`
(plus LICENSE). Upstream's tests, docs, tools, and the `clickhouse-posix-io.h`
/ `clickhouse-openssl.h` I/O backends are not shipped — the extension is
ioless (Ruby owns the socket and TLS).

## Local patches

- `clickhouse.h` — `chc__col_read`, `case CHC_TUPLE`: ClickHouse serializes the
  empty `Tuple()` as one UInt8 (zero) per row (ClickHouse/ClickHouse#55061);
  upstream reads nothing and desyncs the stream. Marked with
  `LOCAL PATCH (ch_connect)`. Should be upstreamed.

## Updating

Clone the pinned or newer commit, copy the four headers + LICENSE over this
directory, re-apply the patches above (or drop them once fixed upstream), and
run the full spec suite with `CH_TRANSPORT=native`.

The allocation-failure regression in `spec/vendor_alloc_spec.rb` compiles a
small C harness with Ruby's configured compiler. Also run StandardRB, rebuild
the extension and gem, and include the TLS integration specs when updating.
