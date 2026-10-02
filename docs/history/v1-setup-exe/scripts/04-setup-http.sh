#!/bin/bash
# 04-setup-http.sh - Configure and start the WinPE HTTP server (rootless nginx)
#
# Runs nginx WITHOUT sudo: master + workers run as the invoking user, the port is
# unprivileged (HTTP_PORT, default 8088), and pid/logs/temp live under run/ (which
# the user owns). This needs no /var/log/nginx, no `user www-data`, and no group
# mutation. It also NEVER touches other nginx/services — if the port is taken by
# something else it errors out instead of killing it.
#
# Serves:
#   http://<host>:<port>/boot.ipxe   (the iPXE script)
#   http://<host>:<port>/winpe/...   (wimboot + WinPE boot files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/config.sh"

echo "=== Setup HTTP Server (rootless nginx, port $HTTP_PORT) ==="

if ! command -v nginx &>/dev/null; then
    echo "ERROR: nginx not found. Run 01-install-deps.sh first." >&2
    exit 1
fi

# Runtime dir for nginx (config, pid, logs, temp) — user-owned, never served.
RUN_DIR="$PROJECT_ROOT/run"
mkdir -p "$RUN_DIR/tmp"
NGINX_CONF="$RUN_DIR/nginx.conf"
NGINX_PID="$RUN_DIR/nginx.pid"

# --- Stop a previous instance of OUR nginx (by our pid file only) ---
if [[ -f "$NGINX_PID" ]] && kill -0 "$(cat "$NGINX_PID" 2>/dev/null)" 2>/dev/null; then
    echo "Stopping previous project nginx ($(cat "$NGINX_PID"))..."
    nginx -s quit -c "$NGINX_CONF" -p "$RUN_DIR" 2>/dev/null \
        || kill "$(cat "$NGINX_PID")" 2>/dev/null || true
    sleep 1
fi

# If the port is still held (by something that ISN'T our nginx), do NOT kill it —
# the user may run essential services nearby. Tell them to pick another port.
if ss -tuln 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    echo "ERROR: port $HTTP_PORT is in use by another process." >&2
    echo "       Set HTTP_PORT in config.sh to a free port and re-run." >&2
    exit 1
fi

# --- Verify the WinPE files exist (readable is enough; nginx only reads them) ---
if [[ ! -d "http/winpe" ]]; then
    echo "ERROR: http/winpe not found. Run 02-extract-winpe.sh first." >&2
    exit 1
fi
missing=0
for f in bootmgfw.efi BCD boot.sdi boot.wim; do
    [[ -f "http/winpe/$f" ]] || { echo "ERROR: missing http/winpe/$f" >&2; missing=1; }
done
[[ $missing -eq 0 ]] || exit 1

# --- Generate boot.ipxe (HTTP_HOST defaults to the QEMU gateway 10.0.2.2) ---
# 07-setup-physical.sh re-runs this with HTTP_HOST set to the host's real LAN IP.
HTTP_HOST="${HTTP_HOST:-10.0.2.2}"
echo "Generating boot.ipxe (host=${HTTP_HOST} port=${HTTP_PORT})..."
cat > "pxe/boot.ipxe" <<EOF
#!ipxe
set base http://${HTTP_HOST}:${HTTP_PORT}/winpe
echo === Windows 11 Install ===
echo HTTP base: \${base}
echo

echo Loading wimboot...
kernel \${base}/wimboot || shell

echo Loading boot files...
initrd --name bootmgfw.efi \${base}/bootmgfw.efi
initrd --name BCD          \${base}/BCD
initrd --name boot.sdi     \${base}/boot.sdi
initrd --name boot.wim     \${base}/boot.wim

echo Starting Windows PE...
boot

echo boot failed - dropping to shell
shell
EOF
# nginx serves /boot.ipxe from the http/ root.
cp "pxe/boot.ipxe" "http/boot.ipxe"

# --- nginx config (rootless: no `user` directive; all paths user-writable) ---
echo "Writing nginx config: $NGINX_CONF"
cat > "$NGINX_CONF" <<EOF
worker_processes auto;
pid $NGINX_PID;
error_log $RUN_DIR/error.log warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log $RUN_DIR/access.log;
    client_body_temp_path $RUN_DIR/tmp;
    proxy_temp_path $RUN_DIR/tmp;
    fastcgi_temp_path $RUN_DIR/tmp;
    uwsgi_temp_path $RUN_DIR/tmp;
    scgi_temp_path $RUN_DIR/tmp;

    # sendfile + tcp_nopush make serving the ~500 MB boot.wim efficient.
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    server {
        listen ${HTTP_PORT};
        server_name localhost;
        root ${PROJECT_ROOT}/http;

        location /winpe/ {
            alias ${PROJECT_ROOT}/http/winpe/;
            autoindex off;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }

        location /health {
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }

        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }
    }
}
EOF

# --- Validate + start (rootless) ---
echo "Testing nginx configuration..."
nginx -t -c "$NGINX_CONF" -p "$RUN_DIR"

echo "Starting nginx on port $HTTP_PORT (rootless, as $(id -un))..."
nginx -c "$NGINX_CONF" -p "$RUN_DIR"

sleep 1
if ! ss -tuln 2>/dev/null | grep -q ":${HTTP_PORT} "; then
    echo "ERROR: nginx failed to start on port $HTTP_PORT (see $RUN_DIR/error.log)" >&2
    exit 1
fi
echo "nginx started."

# --- Verify an endpoint ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/winpe/boot.wim" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    echo "HTTP endpoint verified: http://127.0.0.1:${HTTP_PORT}/winpe/boot.wim"
else
    echo "WARNING: endpoint check returned $HTTP_CODE (expected 200)"
fi

echo ""
echo "HTTP server setup complete!"
echo "  - Port: $HTTP_PORT   Root: ${PROJECT_ROOT}/http   Runtime: $RUN_DIR"
echo "  - Stop it with: scripts/99-teardown.sh"
echo ""
echo "Next: Run 05-create-vm.sh"
