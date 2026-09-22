#!/bin/sh
# Image-level end-to-end test. Run on a host that has docker + this repo:
#
#   sh tests/ci-e2e.sh [image-tag]
#
# Builds nothing: pass the image you want to exercise (default
# xray-northflank:ci). It starts a server container, copies the probe and
# client helpers in, and runs tests/ci-e2e.sh inside it.
set -eu

IMAGE="${1:-xray-northflank:ci}"
CTR="xnf-ci-e2e"
HERE="$(cd "$(dirname "$0")" && pwd)"
UUID="$(cat /proc/sys/kernel/random/uuid)"
SUB_NAME="sub-$(printf '%s' ci-token | sha256sum | cut -c1-16)"

cleanup() { docker rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
docker run -d --name "$CTR" \
    -e UUID="$UUID" \
    -e PUBLIC_HOST="example.code.run" \
    -e ENABLE_WS=true \
    -e SUB_ENABLE=true \
    -e SUB_TOKEN=ci-token \
    -p 18080:8080 \
    "$IMAGE" >/dev/null

# Wait for the container to answer /healthz before probing it.
i=1
while [ "$i" -le 30 ]; do
    if curl -fsS --max-time 5 http://127.0.0.1:18080/healthz >/dev/null 2>&1; then break; fi
    [ "$i" -eq 30 ] && { echo "healthz never became ready" >&2; docker logs "$CTR"; exit 1; }
    i=$((i + 1))
    sleep 1
done

# Render the client config for this container's UUID.
sed "s|__UUID__|$UUID|; s|__HOST__|example.code.run|; s|__WS_PATH__|/ws|" \
    "$HERE/ci-ws-client.json" > /tmp/ci-ws-client.json

docker cp "$HERE/probe-ws-path.sh" "$CTR:/probe.sh"
docker cp "$HERE/ci-e2e.sh"        "$CTR:/ci-e2e.sh"
docker cp /tmp/ci-ws-client.json   "$CTR:/ws-client.json"

docker exec -e UUID="$UUID" -e PUBLIC_HOST=example.code.run -e SUB_NAME="$SUB_NAME" \
    "$CTR" sh /ci-e2e.sh
