#!/usr/bin/env bash
# Full local integration test (NOT part of the image).
#
#   [client xray :socks] --XHTTP/HTTP1.1--> [nginx :8080] --proxy_pass--> [xray :10000]
#
# This reproduces exactly the Northflank topology, minus the edge TLS
# termination (which Northflank performs and we cannot reproduce locally).
#
# usage: integration.sh <rendered site.conf> <rendered config.json>
set -Eeuo pipefail

NGINX="${NGINX_BIN:?set NGINX_BIN to an nginx binary}"
XRAY="${XRAY_BIN:?set XRAY_BIN to an xray binary}"
SITE_CONF="${1:?usage: integration.sh <site.conf> <config.json>}"
XRAY_CONF="${2:?usage: integration.sh <site.conf> <config.json>}"
LISTEN_PORT="${LISTEN_PORT:-18080}"
XRAY_PORT="${XRAY_PORT:-10000}"
XHTTP_PORT="${XHTTP_PORT:-$XRAY_PORT}"
WS_PORT="${WS_PORT:-10001}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
WS_PATH="${WS_PATH:-/ws}"
ENABLE_WS="${ENABLE_WS:-false}"
SOCKS_PORT="${SOCKS_PORT:-11081}"
UUID="${UUID:-de04add9-5c68-8bab-950c-08cd5320df18}"

PREFIX="$(mktemp -d)"
mkdir -p "$PREFIX/logs" "$PREFIX/conf" "$PREFIX/tmp" "$PREFIX/html"
DECOY_DIR="${3:?usage: integration.sh <site.conf> <config.json> <decoy dir>}"

cat > "$PREFIX/conf/mime.types" <<'MT'
types {
    text/html                             html htm;
    text/css                              css;
    application/javascript                js;
    application/json                      json;
    image/png                             png;
    image/svg+xml                         svg;
    text/plain                            txt;
}
MT

# point the vhost's document root at the real decoy directory
sed -i "s|/usr/share/nginx/html|${DECOY_DIR}|g" "$SITE_CONF"

cat > "$PREFIX/conf/nginx.conf" <<CONF
worker_processes 1;
error_log $PREFIX/logs/error.log warn;
pid $PREFIX/nginx.pid;
events { worker_connections 256; }
http {
    include $PREFIX/conf/mime.types;
    default_type application/octet-stream;
    access_log $PREFIX/logs/access.log;
    client_body_temp_path $PREFIX/tmp/client_body;
    proxy_temp_path       $PREFIX/tmp/proxy;
    fastcgi_temp_path     $PREFIX/tmp/fastcgi;
    uwsgi_temp_path       $PREFIX/tmp/uwsgi;
    scgi_temp_path        $PREFIX/tmp/scgi;
    sendfile on;
    keepalive_timeout 65;
    server_tokens off;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;
    # Same upgrade test as nginx/main.conf (a `map` is http-scope only, so the
    # harness has to declare it too or the WS location references an unknown
    # variable).
    map \$http_upgrade \$xnf_ws_upgrade {
        default   0;
        "~*(^|,)\\s*websocket\\s*(,|\$)" 1;
    }
    include $SITE_CONF;
}
CONF

cat > "$PREFIX/client.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": ${SOCKS_PORT}, "protocol": "socks",
      "settings": { "udp": false, "auth": "noauth" } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "127.0.0.1", "port": ${LISTEN_PORT},
            "users": [ { "id": "${UUID}", "encryption": "none" } ] }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "${XHTTP_PATH}", "mode": "auto", "host": "127.0.0.1" }
      }
    }
  ]
}
JSON

echo "=== 1. nginx config syntax ==="
if ! "$NGINX" -t -c "$PREFIX/conf/nginx.conf" -p "$PREFIX" 2>&1 | sed 's/^/   /'; then
    echo "NGINX CONFIG INVALID"; exit 1
fi

echo
echo "=== 2. starting xray backend ==="
"$XRAY" run -c "$XRAY_CONF" > "$PREFIX/xray.log" 2>&1 &
SRV=$!
sleep 2

echo "=== 3. starting nginx ==="
"$NGINX" -c "$PREFIX/conf/nginx.conf" -p "$PREFIX" -g 'daemon off;' > "$PREFIX/nginx.log" 2>&1 &
NGX=$!
sleep 2

cleanup() {
    kill $SRV $NGX ${CLI:-} 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if ! kill -0 $SRV 2>/dev/null; then echo "XRAY DIED"; tail -20 "$PREFIX/xray.log"; exit 1; fi
if ! kill -0 $NGX 2>/dev/null; then echo "NGINX DIED"; tail -20 "$PREFIX/logs/error.log"; exit 1; fi
echo "   both processes alive"

echo
echo "=== 4. decoy site + healthz (plain HTTP through nginx) ==="
echo -n "   /healthz      -> "; curl -sS -m 10 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${LISTEN_PORT}/healthz"
echo -n "   /             -> "; curl -sS -m 10 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${LISTEN_PORT}/"
echo -n "   body contains  -> "; curl -sS -m 10 "http://127.0.0.1:${LISTEN_PORT}/" | grep -o 'Edge Gateway Online' | head -1

if [ "$ENABLE_WS" = "true" ]; then
    echo -n "   probe ${WS_PATH} (no Upgrade header, must stay decoy) -> "
    curl -sS -m 10 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${LISTEN_PORT}${WS_PATH}"
    echo -n "   body is decoy? -> "
    curl -sS -m 10 "http://127.0.0.1:${LISTEN_PORT}${WS_PATH}" | grep -o 'Edge Gateway Online' | head -1
fi

echo
echo "=== 5. tunnel through nginx (SOCKS -> nginx -> xray -> internet) ==="
"$XRAY" run -c "$PREFIX/client.json" > "$PREFIX/client.log" 2>&1 &
CLI=$!
sleep 2
if ! kill -0 $CLI 2>/dev/null; then echo "CLIENT DIED"; tail -20 "$PREFIX/client.log"; exit 1; fi

OUT="$(curl -sS -m 30 --socks5-hostname 127.0.0.1:${SOCKS_PORT} https://www.cloudflare.com/cdn-cgi/trace 2>&1)" && RC=0 || RC=$?
echo "$OUT" | grep -E '^(ip|loc|http|tls)=' | sed 's/^/   /'
echo "   curl_exit=${RC}"

echo
echo "=== 6. nginx access log (XHTTP requests hit the proxy location) ==="
grep -c "${XHTTP_PATH}" "$PREFIX/logs/access.log" 2>/dev/null | sed 's/^/   XHTTP requests logged: /' || echo "   none"

if [ "${RC}" -eq 0 ] && [ -n "$OUT" ]; then
    echo
    echo "RESULT: FULL CHAIN WORKS (client -> nginx -> xray -> internet)"
    exit 0
else
    echo "RESULT: FAILED"
    echo "--- client log ---"; tail -20 "$PREFIX/client.log"
    echo "--- xray log ---";   tail -20 "$PREFIX/xray.log"
    echo "--- nginx error ---"; tail -20 "$PREFIX/logs/error.log"
    exit 1
fi
