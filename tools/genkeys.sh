#!/usr/bin/env bash
# ===========================================================================
#  xray-northflank :: key generator
#  Prints a fresh UUID and a REALITY x25519 keypair.
#  Run it locally (any OS with Docker) or on a VPS:
#      docker run --rm --entrypoint /opt/xnf/genkeys.sh <image>
#  or, with Xray installed locally:
#      ./genkeys.sh
# ===========================================================================
set -Eeuo pipefail

UUID="${UUID:-}"
if [ -z "$UUID" ]; then
    if command -v xray >/dev/null 2>&1; then
        UUID="$(xray uuid)"
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        UUID="$(cat /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen >/dev/null 2>&1; then
        UUID="$(uuidgen | tr 'A-Z' 'a-z')"
    else
        echo "no uuid generator available" >&2; exit 1
    fi
fi

echo "UUID (use as the UUID env var):"
echo "  ${UUID}"
echo

if command -v xray >/dev/null 2>&1; then
    echo "REALITY x25519 keypair (only needed if you run REALITY yourself):"
    xray x25519
else
    echo "xray binary not found - skipping the REALITY keypair." >&2
fi
