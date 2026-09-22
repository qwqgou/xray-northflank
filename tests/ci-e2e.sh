#!/bin/sh
# End-to-end check that runs INSIDE a fresh server container image.
# It is executed by tests/ci-e2e.sh (and can be run by hand) after the
# WebSocket tests have been copied in:
#
#   docker cp tests/probe-ws-path.sh  <ctr>:/probe.sh
#   docker cp tests/ci-ws-client.sh   <ctr>:/ws-client.sh
#   docker cp tests/ci-ws-client.json <ctr>:/ws-client.json
#   docker cp tests/ci-e2e.sh         <ctr>:/ci-e2e.sh
#   docker exec <ctr> sh /ci-e2e.sh
#
# Exits non-zero on the first failed assertion.
set -eu

fail() { echo "FAIL: $*" >&2; exit 1; }

XRAY_LOCATION_ASSET=/usr/local/share/xray
export XRAY_LOCATION_ASSET

echo "=== 1. /healthz ==="
code="$(curl -s -o /tmp/h -w '%{http_code}' --max-time 10 http://127.0.0.1:8080/healthz)"
[ "$code" = "200" ] || fail "/healthz returned $code"
grep -q '^ok' /tmp/h || fail "/healthz body is not 'ok'"

echo "=== 2. decoy page on / ==="
curl -s --max-time 10 http://127.0.0.1:8080/ | grep -q 'Edge Gateway Online' || fail "decoy page missing"

echo "=== 3. WebSocket listener is really up ==="
ss -ltn 2>/dev/null | grep -q ':10001' || fail "xray is not listening on the WS port (10001)"
ss -ltn 2>/dev/null | grep -q ':10000' || fail "xray is not listening on the XHTTP port (10000)"

echo "=== 4. non-upgrade /ws probes must look like the decoy, never like Xray ==="
sh /probe.sh | tee /tmp/probe.out
grep -q "upgrade='none' -> code=200 size=.* decoy=yes" /tmp/probe.out || fail "plain /ws is not the decoy page"
grep -q "upgrade='h2c' -> code=200 size=.* decoy=yes" /tmp/probe.out || fail "h2c probe is not the decoy page"

echo "=== 5. real VLESS+WebSocket tunnel ==="
xray run -c /ws-client.json > /tmp/ws-client.log 2>&1 &
CLIENT_PID=$!
trap 'kill $CLIENT_PID 2>/dev/null || true' EXIT
sleep 3
ws_ip="$(curl -s --max-time 30 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org || true)"
echo "WS tunnel exit IP: ${ws_ip:-<none>}"
[ -n "$ws_ip" ] || { tail -n 20 /tmp/ws-client.log; fail "no egress through the WebSocket tunnel"; }
grep -q 'GET /ws HTTP/1.1" 101' /var/log/nginx/access.log || fail "nginx never completed a WebSocket upgrade (no 101)"
kill $CLIENT_PID 2>/dev/null || true
trap - EXIT

echo "=== 6. real VLESS+XHTTP tunnel ==="
cat > /tmp/xhttp-client.json <<'JSON'
{"log":{"loglevel":"warning"},
 "inbounds":[{"tag":"socks","listen":"127.0.0.1","port":10809,"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"tag":"xh","protocol":"vless",
   "settings":{"vnext":[{"address":"127.0.0.1","port":8080,"users":[{"id":"__UUID__","encryption":"none","flow":""}]}]},
   "streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"__HOST__","path":"/xhttp","mode":"auto"}}}]}
JSON
sed -i "s|__UUID__|${UUID:?UUID env required}|; s|__HOST__|${PUBLIC_HOST:-example.code.run}|" /tmp/xhttp-client.json
xray run -c /tmp/xhttp-client.json > /tmp/xhttp-client.log 2>&1 &
XH_PID=$!
trap 'kill $XH_PID 2>/dev/null || true' EXIT
sleep 3
xh_ip="$(curl -s --max-time 30 --socks5-hostname 127.0.0.1:10809 https://api.ipify.org || true)"
echo "XHTTP tunnel exit IP: ${xh_ip:-<none>}"
[ -n "$xh_ip" ] || { tail -n 20 /tmp/xhttp-client.log; fail "no egress through the XHTTP tunnel"; }
kill $XH_PID 2>/dev/null || true
trap - EXIT

echo "=== 7. subscription files ==="
if [ -n "${SUB_NAME:-}" ]; then
    curl -fsS --max-time 10 "http://127.0.0.1:8080/${SUB_NAME}.yaml" | grep -q 'vless' || fail "clash subscription is not serving vless"
    curl -fsS --max-time 10 "http://127.0.0.1:8080/${SUB_NAME}.txt"  | grep -q 'vless://' || fail "plain subscription is not serving vless://"
fi

echo "ALL E2E CHECKS PASSED"
