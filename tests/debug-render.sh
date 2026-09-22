#!/usr/bin/env bash
# Debug helper: reproduce entrypoint.sh's vhost rendering and show the real
# nginx error instead of the collapsed "failed validation" message.
set -u
export LISTEN_PORT="${LISTEN_PORT:-8080}"
export XRAY_PORT="${XRAY_PORT:-10000}"
export XHTTP_PORT="${XHTTP_PORT:-10000}"
export WS_PORT="${WS_PORT:-10001}"
export WS_PATH="${WS_PATH:-/ws}"
export XHTTP_PATH="${XHTTP_PATH:-/xhttp}"

mkdir -p /etc/nginx/conf.d
envsubst '${LISTEN_PORT} ${XRAY_PORT} ${XHTTP_PORT} ${WS_PORT} ${WS_PATH} ${XHTTP_PATH}' \
    < /etc/nginx/nf-templates/site.conf.tmpl > /etc/nginx/conf.d/site.conf

echo "--- location lines ---"
grep -n 'location' /etc/nginx/conf.d/site.conf
echo "--- listen lines ---"
grep -n 'listen' /etc/nginx/conf.d/site.conf
echo "--- nginx -t (raw) ---"
nginx -t -c /etc/nginx/nginx.conf
echo "nginx_t_exit=$?"
echo "--- nginx -v ---"
nginx -v
