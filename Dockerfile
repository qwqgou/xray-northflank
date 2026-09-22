FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="xray-northflank" \
      org.opencontainers.image.description="Modern Xray (VLESS + WebSocket / XHTTP + TLS) for Northflank free tier" \
      org.opencontainers.image.source="https://github.com/qwqgou/xray-northflank"

ARG XRAY_VERSION=latest
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    LISTEN_PORT=8080 \
    NGINX_CONFIG_TEMPLATE=/etc/nginx/nf-templates/ \
    XRAY_LOCATION_ASSET=/usr/local/share/xray

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl unzip bash nginx iproute2 gettext-base; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install Xray-core, verified against the official .dgst checksum file.
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) XRAY_ARCH="64" ;; \
        arm64) XRAY_ARCH="arm64-v8a" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${XRAY_VERSION}" = "latest" ]; then \
        BASE="https://github.com/XTLS/Xray-core/releases/latest/download"; \
    else \
        BASE="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"; \
    fi; \
    curl -fsSL -o /tmp/xray.zip "${BASE}/Xray-linux-${XRAY_ARCH}.zip"; \
    curl -fsSL -o /tmp/xray.dgst "${BASE}/Xray-linux-${XRAY_ARCH}.zip.dgst"; \
    EXPECTED="$(grep -i '^SHA2-256=' /tmp/xray.dgst | head -n1 | cut -d'=' -f2 | tr -d '[:space:]')"; \
    ACTUAL="$(sha256sum /tmp/xray.zip | cut -d' ' -f1)"; \
    if [ -z "${EXPECTED}" ] || [ "${EXPECTED}" != "${ACTUAL}" ]; then \
        echo "ERROR: Xray checksum mismatch (expected=${EXPECTED} actual=${ACTUAL})" >&2; exit 1; \
    fi; \
    echo "Xray checksum OK: ${ACTUAL}"; \
    mkdir -p /usr/local/share/xray /usr/local/bin; \
    unzip -q -o /tmp/xray.zip -d /tmp/xray; \
    mv /tmp/xray/xray /usr/local/bin/xray; \
    chmod 0755 /usr/local/bin/xray; \
    mv /tmp/xray/geoip.dat /tmp/xray/geosite.dat /usr/local/share/xray/; \
    rm -rf /tmp/xray /tmp/xray.zip /tmp/xray.dgst; \
    /usr/local/bin/xray version

# ---------------------------------------------------------------------------
# nginx: drop the stock site, ship our own templates + decoy page
#
# The `nginx` user is created explicitly on purpose. Debian's nginx package
# normally does that from its maintainer scripts, but on debian:bookworm-slim
# the user is absent, so /etc/nginx/nginx.conf's `user nginx;` makes every
# start (and every `nginx -t`) die with:
#   [emerg] getpwnam("nginx") failed in /etc/nginx/nginx.conf:7
# ---------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; \
    mkdir -p /etc/nginx/nf-templates /var/log/nginx; \
    getent group nginx >/dev/null || groupadd --system nginx; \
    getent passwd nginx >/dev/null || useradd --system \
        --gid nginx --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin --comment "nginx web server" nginx; \
    mkdir -p /var/lib/nginx/body /var/lib/nginx/proxy; \
    chown -R nginx:nginx /var/lib/nginx; \
    chown -R nginx:adm /var/log/nginx

COPY nginx/main.conf       /etc/nginx/nginx.conf
COPY nginx/site.conf.tmpl  /etc/nginx/nf-templates/site.conf.tmpl
COPY nginx/decoy/          /usr/share/nginx/html/
COPY entrypoint.sh         /entrypoint.sh
COPY tools/                /opt/xnf/

# Fail the build - not the container - when a required runtime tool or the
# nginx user is missing, and when the stock nginx.conf is not valid.
RUN set -eux; \
    chmod 0755 /entrypoint.sh; \
    chmod 0755 /opt/xnf/*.sh 2>/dev/null || true; \
    for t in envsubst xray nginx curl sed grep awk; do \
        command -v "$t" >/dev/null 2>&1 || { echo "ERROR: required tool '$t' is missing" >&2; exit 1; }; \
    done; \
    getent passwd nginx >/dev/null || { echo "ERROR: the 'nginx' user does not exist" >&2; exit 1; }; \
    nginx -t -c /etc/nginx/nginx.conf

# Northflank auto-detects EXPOSE as an HTTP port (public by default).
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${LISTEN_PORT}/healthz" -o /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
