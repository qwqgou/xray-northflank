#!/usr/bin/env bash
# ===========================================================================
#  xray-northflank :: entrypoint
#  - renders the nginx vhost + Xray config from templates
#  - prints ready-to-import VLESS links / subscription URLs
#  - runs nginx (public HTTP) + xray (localhost tunnel backend)
# ===========================================================================
set -Eeuo pipefail

TMPL_DIR="/etc/nginx/nf-templates"
XRAY_CONF="/etc/xray/config.json"
XRAY_CONF_TMPL="/opt/xnf/config.json.tmpl"
SITE_TMPL="${TMPL_DIR}/site.conf.tmpl"
SITE_OUT="/etc/nginx/conf.d/site.conf"
HTML_DIR="/usr/share/nginx/html"

log()  { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { printf '%s FATAL: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

# `--check` renders + validates everything and exits without starting services.
# CI uses it so the very same code path the container runs at boot is tested.
CHECK_ONLY=false
case "${1:-}" in
    --check|--validate) CHECK_ONLY=true ;;
esac

sha256hex() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else openssl dgst -sha256 -r | cut -d' ' -f1; fi
}

is_true() { case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# delete every line from the START marker through the END marker (inclusive).
# Fails loudly if the markers are missing, because silently producing a broken
# config is far worse than refusing to start.
strip_block() {
    local file="$1" start="$2" end="$3"
    # A marker is any line where the name appears delimited by non-word
    # characters, which covers both `# NAME` (nginx) and `/* NAME` (JSONC).
    # Anchoring this way keeps documentation mentions of the name from counting.
    local re_start="(^|[^A-Za-z0-9_])${start}([^A-Za-z0-9_]|$)"
    local re_end="(^|[^A-Za-z0-9_])${end}([^A-Za-z0-9_]|$)"
    local n
    n="$(grep -cE "$re_start" "$file" || true)"
    [ "$n" -eq 1 ] || die "template marker $start appears $n time(s), expected exactly 1"
    grep -qE "$re_end" "$file" || die "template marker $end is missing"
    sed -E "/$re_start/,/$re_end/d" "$file"
}

# ------------------------------------------------------------------ booleans
ENABLE_WS="$(printf '%s' "${ENABLE_WS:-false}" | tr 'A-Z' 'a-z')"
SUB_ENABLE="$(printf '%s' "${SUB_ENABLE:-false}" | tr 'A-Z' 'a-z')"

# ------------------------------------------------------------------ LISTEN_PORT
if [ -n "${PORT:-}" ]; then
    LISTEN_PORT="$PORT"
else
    LISTEN_PORT="${LISTEN_PORT:-8080}"
fi
case "$LISTEN_PORT" in
    ''|*[!0-9]*) die "LISTEN_PORT/PORT must be numeric, got '${LISTEN_PORT}'" ;;
esac

# ------------------------------------------------------------------ UUID
UUID="${UUID:-}"
if [ -z "$UUID" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        UUID="$(cat /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen >/dev/null 2>&1; then
        UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    else
        die "no UUID provided and no way to generate one"
    fi
    warn "UUID was not set: generated a random one for THIS container only."
    warn "The UUID changes on every restart - set the UUID env var in Northflank."
fi

# ------------------------------------------------------------------ paths/ports
norm_path() { printf '/%s' "$(printf '%s' "$1" | sed 's|^/*||; s|/*$||')"; }

WS_PATH="$(norm_path "${WS_PATH:-ws}")"
XHTTP_PATH="$(norm_path "${XHTTP_PATH:-xhttp}")"
XRAY_PORT="${XRAY_PORT:-10000}"
XHTTP_PORT="${XHTTP_PORT:-$XRAY_PORT}"
WS_PORT="${WS_PORT:-10001}"
case "$XRAY_PORT" in ''|*[!0-9]*) die "XRAY_PORT must be numeric" ;; esac
case "$XHTTP_PORT" in ''|*[!0-9]*) die "XHTTP_PORT must be numeric" ;; esac
case "$WS_PORT" in ''|*[!0-9]*) die "WS_PORT must be numeric" ;; esac
[ "$XRAY_PORT" = "$LISTEN_PORT" ] && die "XRAY_PORT and LISTEN_PORT must differ"
[ "$WS_PATH" = "$XHTTP_PATH" ]    && die "WS_PATH and XHTTP_PATH must differ"
# XHTTP and WebSocket must NOT share a port: when two Xray inbounds listen on
# the same address+port, the transport multiplexer answers the WebSocket
# handshake with a bare "404 Not Found" and the WS transport can never connect.
[ "$WS_PORT" = "$XHTTP_PORT" ] && die "WS_PORT and XHTTP_PORT must differ (Xray cannot serve WS and XHTTP on one port)"

# ------------------------------------------------------------------ public host
PUBLIC_HOST="${PUBLIC_HOST:-${SPACE_HOST:-${NF_HOST:-}}}"
PUBLIC_HOST="${PUBLIC_HOST#http://}"; PUBLIC_HOST="${PUBLIC_HOST#https://}"
PUBLIC_HOST="${PUBLIC_HOST%%/*}";     PUBLIC_HOST="${PUBLIC_HOST%%:*}"
PUBLIC_HOST="$(printf '%s' "$PUBLIC_HOST" | tr 'A-Z' 'a-z')"

# ------------------------------------------------------------------ nginx vhost
[ -f "$SITE_TMPL" ] || die "missing $SITE_TMPL - image build is broken"
export LISTEN_PORT XRAY_PORT XHTTP_PORT WS_PORT WS_PATH XHTTP_PATH
mkdir -p /etc/nginx/conf.d

render_nginx() {
    envsubst '${LISTEN_PORT} ${XRAY_PORT} ${XHTTP_PORT} ${WS_PORT} ${WS_PATH} ${XHTTP_PATH}' < "$SITE_TMPL"
}

# `--check` additionally dumps the rendered configs to stdout. stdout is
# redirected to a file for boot, so in check mode send them to stderr instead;
# CI captures that to inspect exactly what would have been written.
dump_rendered() {
    if [ "$CHECK_ONLY" = true ]; then cat "$@" >&2; else cat "$@"; fi
}

render_nginx > "${SITE_OUT}.tmp"
if is_true "$ENABLE_WS"; then
    mv "${SITE_OUT}.tmp" "$SITE_OUT"
else
    strip_block "${SITE_OUT}.tmp" 'WG_WS_START' 'WG_WS_END' > "$SITE_OUT"
    rm -f "${SITE_OUT}.tmp"
fi
rm -f "$SITE_TMPL"

# Safety net: stripping the WS block must never unbalance the server braces.
_open="$(grep -o '{' "$SITE_OUT" | wc -l)"
_close="$(grep -o '}' "$SITE_OUT" | wc -l)"
[ "$_open" -eq "$_close" ] || die "rendered nginx vhost has unbalanced braces (${_open} open / ${_close} close)"

# ------------------------------------------------------------------ xray config
mkdir -p "$(dirname "$XRAY_CONF")"
sed -e "s|__XRAY_PORT__|${XHTTP_PORT}|g" \
    -e "s|__WS_PORT__|${WS_PORT}|g" \
    -e "s|__UUID__|${UUID}|g" \
    -e "s|__WS_PATH__|${WS_PATH}|g" \
    -e "s|__XHTTP_PATH__|${XHTTP_PATH}|g" \
    "$XRAY_CONF_TMPL" > "${XRAY_CONF}.tmp"
if is_true "$ENABLE_WS"; then
    mv "${XRAY_CONF}.tmp" "$XRAY_CONF"
else
    strip_block "${XRAY_CONF}.tmp" 'WS_INBOUND_START' 'WS_INBOUND_END' > "$XRAY_CONF"
    rm -f "${XRAY_CONF}.tmp"
fi

log "checking generated configs..."
if ! nginx -t -q -c /etc/nginx/nginx.conf 2>/tmp/nginx-check.log; then
    cat /tmp/nginx-check.log >&2
    cat "$SITE_OUT" >&2
    die "generated nginx config failed validation"
fi
log "nginx config OK"
if ! xray run -test -c "$XRAY_CONF" >/tmp/xray-check.log 2>&1; then
    cat /tmp/xray-check.log >&2
    die "generated Xray config failed validation"
fi
log "Xray config OK ($(grep -c '"tag": "vless-' "$XRAY_CONF") inbound(s))"

# In check mode stdout is redirected to a file for boot, so the dumps are sent
# to the log stream instead and stay out of the rendered output.
{
    echo "-----8<----- rendered nginx vhost (ENABLE_WS=${ENABLE_WS}) -----8<-----"
    dump_rendered "$SITE_OUT"
    echo "-----8<----- rendered Xray config -----8<-----"
    dump_rendered "$XRAY_CONF"
    echo "-----8<----- end of rendered configs -----8<-----"
} >&2

# ------------------------------------------------------------------ decoy site
# Give the root page a name matching the host so the site looks intentional.
if [ -n "$PUBLIC_HOST" ]; then
    sed -i "s|__SITE_HOST__|${PUBLIC_HOST}|g" "${HTML_DIR}/index.html" || true
else
    sed -i "s|__SITE_HOST__|this server|g" "${HTML_DIR}/index.html" || true
fi

# ------------------------------------------------------------------ client links
build_link_ws()    { printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=http%%2F1.1&fp=chrome&type=ws&host=%s&path=%s#%s' \
                          "$UUID" "$PUBLIC_HOST" "$PUBLIC_HOST" "$PUBLIC_HOST" "$WS_PATH" "$1"; }
build_link_xhttp() { printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&alpn=http%%2F1.1&fp=chrome&type=xhttp&host=%s&path=%s&mode=auto#%s' \
                          "$UUID" "$PUBLIC_HOST" "$PUBLIC_HOST" "$PUBLIC_HOST" "$XHTTP_PATH" "$1"; }
build_link_direct() { printf 'vless://%s@%s:%s?encryption=none&security=none&type=%s&host=%s&path=%s&mode=auto#%s' \
                          "$UUID" "$PUBLIC_HOST" "$LISTEN_PORT" "$1" "$PUBLIC_HOST" "$2" "$3"; }

NODE_TAG="${NODE_TAG:-NF}"
EDGE_HOST="${PUBLIC_HOST:-__HOST__}"

write_clash_config() {
    cat > "$1" <<YAML
# xray-northflank :: Clash Meta / mihomo config
# If "__HOST__" still appears below, set PUBLIC_HOST and redeploy.
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
proxies:
  - name: "${NODE_TAG}-xhttp"
    type: vless
    server: ${EDGE_HOST}
    port: 443
    uuid: ${UUID}
    network: xhttp
    tls: true
    udp: true
    servername: ${EDGE_HOST}
    client-fingerprint: chrome
    alpn: [http/1.1]
    xhttp-opts:
      path: "${XHTTP_PATH}"
      mode: auto
      headers:
        Host: ${EDGE_HOST}
YAML
    if is_true "$ENABLE_WS"; then
        cat >> "$1" <<YAML
  - name: "${NODE_TAG}-ws"
    type: vless
    server: ${EDGE_HOST}
    port: 443
    uuid: ${UUID}
    network: ws
    tls: true
    udp: true
    servername: ${EDGE_HOST}
    client-fingerprint: chrome
    alpn: [http/1.1]
    ws-opts:
      path: "${WS_PATH}"
      headers:
        Host: ${EDGE_HOST}
YAML
    fi
    cat >> "$1" <<YAML
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${NODE_TAG}-xhttp"
YAML
    if is_true "$ENABLE_WS"; then
        printf '      - "%s-ws"\n' "$NODE_TAG" >> "$1"
    fi
    cat >> "$1" <<YAML
      - DIRECT
rules:
  - GEOIP,private,DIRECT,no-resolve
  - MATCH,PROXY
YAML
}

# ------------------------------------------------------------------ subscription
SUB_PATH=""
if is_true "$SUB_ENABLE"; then
    if [ -n "${SUB_TOKEN:-}" ]; then
        SUB_NAME="sub-$(printf '%s' "$SUB_TOKEN" | sha256hex | cut -c1-16)"
    else
        SUB_NAME="sub-$(printf '%s' "$UUID" | sha256hex | cut -c1-16)"
        warn "SUB_TOKEN not set: the subscription filename is derived from the UUID."
        warn "Anyone who can guess that filename gets your UUID. Set SUB_TOKEN."
    fi
    {
        build_link_xhttp "${NODE_TAG}-xhttp"; echo
        if is_true "$ENABLE_WS"; then build_link_ws "${NODE_TAG}-ws"; echo; fi
        if [ -n "$PUBLIC_HOST" ]; then
            build_link_direct xhttp "$XHTTP_PATH" "${NODE_TAG}-xhttp-direct"; echo
        fi
    } > "${HTML_DIR}/${SUB_NAME}.txt"
    write_clash_config "${HTML_DIR}/${SUB_NAME}.yaml"
    SUB_PATH="$SUB_NAME"
fi

# ------------------------------------------------------------------ banner
{
    echo
    echo "================================================================================"
    echo "  xray-northflank is up"
    echo "================================================================================"
    echo "  Xray core       : $(xray version | head -n1 | awk '{print $1, $2}')"
    echo "  container port  : ${LISTEN_PORT}  (Northflank maps this to public 443)"
    echo "  xray backend    : 127.0.0.1:${XRAY_PORT}"
    echo "  UUID            : ${UUID}"
    if is_true "$ENABLE_WS"; then
        echo "  XHTTP path      : ${XHTTP_PATH}"
        echo "  WS path         : ${WS_PATH}  (deprecated transport, enabled)"
    else
        echo "  XHTTP path      : ${XHTTP_PATH}"
    fi
    echo "  public host     : ${PUBLIC_HOST:-<not detected - set PUBLIC_HOST>}"
    echo
    if [ -n "$PUBLIC_HOST" ]; then
        echo "  [1] VLESS + XHTTP + TLS   <- recommended, current-generation transport"
        echo "      $(build_link_xhttp "${NODE_TAG}-xhttp")"
        echo
        if is_true "$ENABLE_WS"; then
            echo "  [2] VLESS + WebSocket + TLS"
            echo "      $(build_link_ws "${NODE_TAG}-ws")"
            echo
        fi
        echo "  [3] direct-to-container, no edge TLS (only if you front it yourself)"
        echo "      $(build_link_direct xhttp "$XHTTP_PATH" "${NODE_TAG}-xhttp-direct")"
        echo
        if [ -n "$SUB_PATH" ]; then
            echo "  Subscription"
            echo "    Clash Meta : https://${PUBLIC_HOST}/${SUB_PATH}.yaml"
            echo "    plain links: https://${PUBLIC_HOST}/${SUB_PATH}.txt"
            echo
        fi
    else
        echo "  Could not detect the public hostname, so no client links are shown."
        echo "  Northflank does not inject it: set PUBLIC_HOST=<your>.code.run and"
        echo "  redeploy (see README)."
        echo
    fi
    echo "  Next: import the link above in v2rayN / v2rayNG / NekoBox / sing-box /"
    echo "        Shadowrocket / Clash Meta, then browse."
    echo "================================================================================"
    echo
} 

# ------------------------------------------------------------------ check mode
if [ "$CHECK_ONLY" = true ]; then
    log "check mode: every config validated, not starting services"
    exit 0
fi

# ------------------------------------------------------------------ run
cleanup() {
    log "shutting down..."
    nginx -s quit 2>/dev/null || true
    if [ -n "${XRAY_PID:-}" ]; then kill "$XRAY_PID" 2>/dev/null || true; fi
    wait 2>/dev/null || true
}
trap cleanup TERM INT

xray run -c "$XRAY_CONF" &
XRAY_PID=$!
log "xray started (pid ${XRAY_PID})"
sleep 1
kill -0 "$XRAY_PID" 2>/dev/null || die "xray exited immediately - check the config above"

nginx -g 'daemon off;' -c /etc/nginx/nginx.conf &
NGINX_PID=$!
log "nginx started (pid ${NGINX_PID})"
sleep 1
kill -0 "$NGINX_PID" 2>/dev/null || die "nginx exited immediately - check the config above"

log "ready on 0.0.0.0:${LISTEN_PORT}"

# If either process dies, take the container down so the platform restarts it.
wait -n "$XRAY_PID" "$NGINX_PID" || true
log "a service exited - shutting down container"
cleanup
exit 1
