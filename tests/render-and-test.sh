#!/usr/bin/env bash
# Local verification harness (NOT part of the image).
# Reproduces the exact template rendering that entrypoint.sh performs, then
# checks the result with a real Xray binary.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: render-and-test.sh <outdir>}"
XRAY="${XRAY_BIN:?set XRAY_BIN to a linux xray binary}"
ENABLE_WS="${ENABLE_WS:-false}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
XRAY_PORT="${XRAY_PORT:-10000}"
XHTTP_PORT="${XHTTP_PORT:-$XRAY_PORT}"
WS_PORT="${WS_PORT:-10001}"
UUID="${UUID:-de04add9-5c68-8bab-950c-08cd5320df18}"
WS_PATH="${WS_PATH:-/ws}"
XHTTP_PATH="${XHTTP_PATH:-/xhttp}"

mkdir -p "$OUT"

strip_block() {
    local file="$1" start="$2" end="$3" n
    local re_start="(^|[^A-Za-z0-9_])${start}([^A-Za-z0-9_]|$)"
    local re_end="(^|[^A-Za-z0-9_])${end}([^A-Za-z0-9_]|$)"
    n="$(grep -cE "$re_start" "$file" || true)"
    [ "$n" -eq 1 ] || { echo "MARKER $start appears $n times (expected 1)" >&2; return 1; }
    grep -qE "$re_end" "$file" || { echo "MARKER $end missing" >&2; return 1; }
    sed -E "/$re_start/,/$re_end/d" "$file"
}

# ---- nginx vhost (envsubst equivalent) ----
# NOTE: substitute the paths verbatim, exactly like entrypoint.sh does with
# envsubst. Stripping the leading "/" here would hide the "//xhttp" bug that
# production hit, because the template used to add its own leading slash.
sed -e "s|\${LISTEN_PORT}|${LISTEN_PORT}|g" \
    -e "s|\${XRAY_PORT}|${XRAY_PORT}|g" \
    -e "s|\${XHTTP_PORT}|${XHTTP_PORT}|g" \
    -e "s|\${WS_PORT}|${WS_PORT}|g" \
    -e "s|\${WS_PATH}|${WS_PATH}|g" \
    -e "s|\${XHTTP_PATH}|${XHTTP_PATH}|g" \
    "$ROOT/nginx/site.conf.tmpl" > "$OUT/site.raw.conf"
if [ "$ENABLE_WS" = "true" ]; then
    mv "$OUT/site.raw.conf" "$OUT/site.conf"
else
    strip_block "$OUT/site.raw.conf" 'WG_WS_START' 'WG_WS_END' > "$OUT/site.conf"
fi

# the same brace assertion entrypoint.sh performs
open="$(grep -o '{' "$OUT/site.conf" | wc -l)"
close="$(grep -o '}' "$OUT/site.conf" | wc -l)"
echo "--- vhost brace balance: ${open} open / ${close} close ---"
if [ "$open" -ne "$close" ]; then echo "UNBALANCED BRACES"; exit 1; fi

# ---- xray config ----
sed -e "s|__XRAY_PORT__|${XHTTP_PORT}|g" \
    -e "s|__WS_PORT__|${WS_PORT}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__WS_PATH__|${WS_PATH}|g" \
    -e "s|__XHTTP_PATH__|${XHTTP_PATH}|g" \
    "$ROOT/tools/config.json.tmpl" > "$OUT/xray.raw.json"
if [ "$ENABLE_WS" = "true" ]; then
    mv "$OUT/xray.raw.json" "$OUT/config.json"
else
    strip_block "$OUT/xray.raw.json" 'WS_INBOUND_START' 'WS_INBOUND_END' > "$OUT/config.json"
fi

echo "=== rendered (ENABLE_WS=${ENABLE_WS}) ==="
"$XRAY" run -test -c "$OUT/config.json" 2>&1 | grep -vE 'Penetrates|unified platform'
echo "--- nginx WS block present? ---"
if grep -q '__ws__' "$OUT/site.conf"; then echo "yes"; else echo "no (stripped)"; fi
echo "--- marker cleanup check (both must be 0 when stripped) ---"
grep -c 'WS_BLOCK_START' "$OUT/site.conf" || true
grep -c 'WS_INBOUND_START' "$OUT/config.json" || true
