#!/usr/bin/env bash
# Entry point used by the Windows host to run the suite inside WSL.
set -uo pipefail
cd /mnt/d/software_project/default/xray-northflank || exit 1
export XRAY_BIN="$HOME/xnf-test/bin/xray"
export NGINX_BIN="/tmp/nginxroot/usr/sbin/nginx"
export LISTEN_PORT="${LISTEN_PORT:-18080}"
export XRAY_PORT="${XRAY_PORT:-10000}"
exec bash tests/run-all.sh
