#!/usr/bin/env bash
# Starts a TLS-enabled ClickHouse container for the TLS specs.
#
# Usage: spec/support/start_tls_clickhouse.sh <cert_dir> [password]
#
# Then run the specs with:
#   CH_TLS_PORT=9440 CH_TLS_CA=<cert_dir>/server.crt bundle exec rspec
set -euo pipefail

CERT_DIR="${1:?usage: $0 <cert_dir> [password]}"
PASSWORD="${2:-default}"

mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" -days 3650 -nodes -subj "/CN=localhost" 2>/dev/null
chmod 644 "$CERT_DIR/server.key" "$CERT_DIR/server.crt"

cat > "$CERT_DIR/ssl.xml" <<'XML'
<clickhouse>
    <tcp_port_secure>9440</tcp_port_secure>
    <openSSL>
        <server>
            <certificateFile>/etc/clickhouse-server/certs/server.crt</certificateFile>
            <privateKeyFile>/etc/clickhouse-server/certs/server.key</privateKeyFile>
            <verificationMode>none</verificationMode>
            <loadDefaultCAFile>true</loadDefaultCAFile>
            <cacheSessions>true</cacheSessions>
            <disableProtocols>sslv2,sslv3</disableProtocols>
            <preferServerCiphers>true</preferServerCiphers>
        </server>
    </openSSL>
</clickhouse>
XML

docker rm -f clickhouse-tls-test >/dev/null 2>&1 || true
docker run -d --name clickhouse-tls-test \
  -p 9440:9440 \
  -e CLICKHOUSE_PASSWORD="$PASSWORD" \
  -v "$CERT_DIR/ssl.xml:/etc/clickhouse-server/config.d/ssl.xml:ro" \
  -v "$CERT_DIR/server.crt:/etc/clickhouse-server/certs/server.crt:ro" \
  -v "$CERT_DIR/server.key:/etc/clickhouse-server/certs/server.key:ro" \
  clickhouse/clickhouse-server >/dev/null

for _ in $(seq 1 30); do
  if openssl s_client -connect localhost:9440 </dev/null >/dev/null 2>&1; then
    echo "TLS ClickHouse ready on :9440 (CA: $CERT_DIR/server.crt)"
    exit 0
  fi
  sleep 1
done

echo "TLS ClickHouse failed to start" >&2
docker logs clickhouse-tls-test 2>&1 | tail -20 >&2
exit 1
