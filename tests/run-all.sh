#!/usr/bin/env bash
# Orchestrates the full local verification suite (NOT part of the image).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export XRAY_BIN="${XRAY_BIN:?}"
export NGINX_BIN="${NGINX_BIN:?}"
export LISTEN_PORT="${LISTEN_PORT:-18080}"
export XRAY_PORT="${XRAY_PORT:-10000}"
export XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
export WS_PATH="${WS_PATH:-/ws}"

PASS=0; FAIL=0
declare -a RESULTS

run_case() {
    local enable_ws="$1"
    local tag="ENABLE_WS=${enable_ws}"
    local out="/tmp/xnf-case-${enable_ws}"
    rm -rf "$out"
    echo
    echo "################################################################"
    echo "###  CASE ${tag}"
    echo "################################################################"
    export ENABLE_WS="$enable_ws"

    if ! timeout 120 bash "$ROOT/tests/render-and-test.sh" "$out"; then
        RESULTS+=("FAIL  render/validate  ${tag}"); FAIL=$((FAIL+1)); return
    fi
    RESULTS+=("PASS  render/validate  ${tag}"); PASS=$((PASS+1))

    if timeout 240 bash "$ROOT/tests/integration.sh" "$out/site.conf" "$out/config.json" "$ROOT/nginx/decoy"; then
        RESULTS+=("PASS  full chain       ${tag}"); PASS=$((PASS+1))
    else
        RESULTS+=("FAIL  full chain       ${tag}"); FAIL=$((FAIL+1))
    fi
    # integration.sh rewrites site.conf in place; re-render for the next case
    rm -rf "$out"
}

run_case false
run_case true

# also verify nginx rejects a genuinely broken vhost (sanity check that -t works)
echo
echo "################################################################"
echo "###  CASE negative control (nginx must reject a bad directive)"
echo "################################################################"
tmp="$(mktemp -d)"
echo 'server { nonsense_directive on; }' > "$tmp/bad.conf"
cat > "$tmp/nginx.conf" <<CONF
worker_processes 1;
error_log $tmp/err.log;
pid $tmp/nginx.pid;
events { worker_connections 64; }
http { include $tmp/bad.conf; }
CONF
if "$NGINX_BIN" -t -c "$tmp/nginx.conf" -p "$tmp" >/dev/null 2>&1; then
    echo "   nginx ACCEPTED an invalid config - validation is not trustworthy"
    RESULTS+=("FAIL  negative control"); FAIL=$((FAIL+1))
else
    echo "   nginx correctly rejected it"
    RESULTS+=("PASS  negative control"); PASS=$((PASS+1))
fi
rm -rf "$tmp"

echo
echo "=================================================================="
echo "  SUMMARY"
echo "=================================================================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "  ----"
echo "  passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
