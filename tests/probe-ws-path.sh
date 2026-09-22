#!/bin/sh
# Probe the WebSocket path with different Upgrade header values.
set -u
BASE="http://127.0.0.1:8080/ws"

probe() {
    label="$1"; shift
    code="$(curl -s -o /tmp/probe.body -w '%{http_code}' "$@" "$BASE")"
    decoy="no"
    grep -q 'Edge Gateway Online' /tmp/probe.body 2>/dev/null && decoy="yes"
    size="$(wc -c < /tmp/probe.body)"
    echo "upgrade='${label}' -> code=${code} size=${size} decoy=${decoy}"
}

probe "none"
probe "websocket"        -H 'Upgrade: websocket'    -H 'Connection: Upgrade'
probe "WebSocket"        -H 'Upgrade: WebSocket'    -H 'Connection: Upgrade'
probe "keep-alive,Upgrade" -H 'Upgrade: keep-alive, Upgrade' -H 'Connection: Upgrade'
probe "h2c"              -H 'Upgrade: h2c'          -H 'Connection: Upgrade'
probe "websocket,no-conn" -H 'Upgrade: websocket'
