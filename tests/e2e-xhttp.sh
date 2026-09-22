#!/usr/bin/env bash
# Local end-to-end tunnel test (NOT part of the image).
#
#   [server xray :XRAY_PORT]  <-- HTTP/1.1 XHTTP -->  [client xray :socks]
#   then curl through the client's SOCKS5 proxy.
#
# This exercises exactly what nginx/Northflank's edge does: forward plain
# HTTP/1.1 requests to Xray's XHTTP inbound.
set -Eeuo pipefail

XRAY="${XRAY_BIN:?set XRAY_BIN}"
SERVER_CONF="${1:?usage: e2e-xhttp.sh <server config.json>}"
XRAY_PORT="${XRAY_PORT:-10000}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
SOCKS_PORT="${SOCKS_PORT:-11080}"
WORK="$(mktemp -d)"
UUID="${UUID:-de04add9-5c68-8bab-950c-08cd5320df18}"

cat > "$WORK/client.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": { "udp": false, "auth": "noauth" }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": ${XRAY_PORT},
            "users": [ { "id": "${UUID}", "encryption": "none" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "host": "127.0.0.1"
        }
      }
    }
  ]
}
JSON

echo "=== client config check ==="
"$XRAY" run -test -c "$WORK/client.json" 2>&1 | grep -vE 'Penetrates|unified platform'

"$XRAY" run -c "$SERVER_CONF" > "$WORK/server.log" 2>&1 &
SRV=$!
"$XRAY" run -c "$WORK/client.json" > "$WORK/client.log" 2>&1 &
CLI=$!
trap 'kill $SRV $CLI 2>/dev/null || true; wait 2>/dev/null || true' EXIT
sleep 2

echo
echo "=== server log ==="
cat "$WORK/server.log" | grep -vE 'Penetrates|unified platform' || true
echo "=== client log ==="
cat "$WORK/client.log" | grep -vE 'Penetrates|unified platform' || true

if ! kill -0 $SRV 2>/dev/null; then echo "SERVER DIED"; exit 1; fi
if ! kill -0 $CLI 2>/dev/null; then echo "CLIENT DIED"; exit 1; fi

echo
echo "=== curl through the tunnel (https://www.cloudflare.com/cdn-cgi/trace) ==="
OUT="$(curl -sS -m 25 --socks5-hostname 127.0.0.1:${SOCKS_PORT} https://www.cloudflare.com/cdn-cgi/trace 2>&1)" && RC=0 || RC=$?
echo "$OUT" | head -20
echo "curl_exit=${RC}"
if [ "${RC}" -eq 0 ] && [ -n "$OUT" ]; then
    echo "RESULT: TUNNEL WORKS"
else
    echo "RESULT: TUNNEL FAILED"
    echo "--- client log tail ---"; tail -30 "$WORK/client.log"
    echo "--- server log tail ---"; tail -30 "$WORK/server.log"
    exit 1
fi
