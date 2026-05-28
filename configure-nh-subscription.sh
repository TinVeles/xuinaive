#!/usr/bin/env bash
# Expose NHM Panel /sub/<TOKEN>/ subscription endpoint over HTTPS via nginx
# stream SNI routing. Use when PANEL_ACCESS=ssh-tunnel (default) is too
# restrictive and clients need to reach subscription URLs publicly.
#
# Prerequisites:
#   * Public DNS A/AAAA record for --domain pointing to this VPS.
#   * Let's Encrypt cert at /etc/letsencrypt/live/<domain>/.
#   * x-ui-pro nginx stream installed and active (provides SNI router on 443).
#   * NHM Panel running on 127.0.0.1:3000.
#
# What it does:
#   1. Provisions a local HTTPS server on 127.0.0.1:$BACKEND_PORT that exposes
#      only /sub/$TOKEN/* and proxies to NHM Panel.
#   2. Adds an SNI map entry in /etc/nginx/stream-enabled/stream.conf so that
#      $DOMAIN traffic on 0.0.0.0:443 is forwarded to that local backend.
#   3. Reloads nginx and tests local + public reachability.

set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"

DOMAIN="${NH_SUB_DOMAIN:-}"
TOKEN_FILE="${NH_SUBSCRIPTION_TOKEN_FILE:-/etc/nh-panel/subscription-token}"
TOKEN="${NH_SUBSCRIPTION_TOKEN:-}"
PANEL_HOST="${NH_PANEL_HOST:-127.0.0.1}"
PANEL_PORT="${NH_PANEL_INTERNAL_PORT:-3000}"
BACKEND_PORT="${NH_SUB_BACKEND_PORT:-9446}"
STREAM_CONF="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}"
ASSUME_YES=0

usage() {
  cat <<EOF
Usage:
  sudo bash configure-nh-subscription.sh --domain SUB_DOMAIN [--token TOKEN] --yes

Options:
  --domain DOMAIN          Public domain that will serve HTTPS subscription URLs
  --token TOKEN            Override subscription token (default: read from $TOKEN_FILE)
  --backend-port PORT      Local HTTPS backend port, default: $BACKEND_PORT
  --panel-host HOST        NHM Panel host, default: $PANEL_HOST
  --panel-port PORT        NHM Panel port, default: $PANEL_PORT
  --yes                    Apply changes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --panel-host) PANEL_HOST="${2:-}"; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid domain: $DOMAIN"
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "--backend-port must be numeric"
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "--panel-port must be numeric"

if [[ -z "$TOKEN" && -s "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -dc 'A-Za-z0-9._-' < "$TOKEN_FILE" | head -c 128)"
fi
[[ -n "$TOKEN" ]] || die "Subscription token not found; provide --token or ensure $TOKEN_FILE is populated"
[[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || die "Token contains unsupported characters"

command_exists nginx || die "nginx is required"
[[ -f "$STREAM_CONF" ]] || die "nginx stream config not found: $STREAM_CONF (run x-ui-pro install first)"

CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
[[ -f "$CERT_FILE" && -f "$CERT_KEY" ]] || die "TLS cert for $DOMAIN not found in /etc/letsencrypt/live/$DOMAIN"

mkdir -p /opt/unified-proxy-manager/backups
BACKUP_DIR="/opt/unified-proxy-manager/backups/nh-subscription-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
for path in "$STREAM_CONF" "$SITES_DIR"; do
  [[ -e "$path" || -L "$path" ]] || continue
  mkdir -p "$BACKUP_DIR$(dirname "$path")"
  cp -aP "$path" "$BACKUP_DIR$(dirname "$path")/"
done

safe_name="$(printf '%s' "$DOMAIN" | tr -c 'A-Za-z0-9' '_')"
upstream_name="upm_${safe_name}_nh_sub"
backend_conf="$SITES_DIR/upm-nh-subscription-$DOMAIN.conf"

info "Writing nginx subscription backend: $backend_conf"
tmp_conf="$(mktemp)"
chmod 0644 "$tmp_conf"
cat > "$tmp_conf" <<EOF
server {
    server_tokens off;
    server_name $DOMAIN;

    listen $BACKEND_PORT ssl http2 proxy_protocol;
    listen [::]:$BACKEND_PORT ssl http2 proxy_protocol;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate $CERT_FILE;
    ssl_certificate_key $CERT_KEY;

    location ~ ^/sub/${TOKEN}/[A-Za-z0-9._-]+\$ {
        proxy_pass http://${PANEL_HOST}:${PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        limit_req zone=upm_nh_sub burst=20 nodelay;
    }

    location / {
        return 404;
    }
}
EOF
install -m 0644 "$tmp_conf" "$backend_conf"
rm -f "$tmp_conf"

# Ensure rate-limit zone is declared once
RATELIMIT_FILE="/etc/nginx/conf.d/upm-nh-sub-ratelimit.conf"
if [[ ! -f "$RATELIMIT_FILE" ]]; then
  cat > "$RATELIMIT_FILE" <<'EOF'
limit_req_zone $binary_remote_addr zone=upm_nh_sub:10m rate=10r/s;
EOF
  chmod 0644 "$RATELIMIT_FILE"
fi

info "Updating nginx stream SNI map for $DOMAIN -> $upstream_name"
tmp_stream="$(mktemp)"
awk -v domain="$DOMAIN" -v upstream="$upstream_name" '
  BEGIN { in_map = 0; done = 0 }
  $0 ~ /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name[[:space:]]*\{/ {
    in_map = 1
    print
    next
  }
  in_map && $0 ~ /^[[:space:]]*hostnames;[[:space:]]*$/ {
    print
    if (!done) {
      printf "    %-32s %s;\n", domain, upstream
      done = 1
    }
    next
  }
  in_map && $0 ~ /^[[:space:]]*\}/ {
    if (!done) {
      printf "    %-32s %s;\n", domain, upstream
      done = 1
    }
    in_map = 0
    print
    next
  }
  in_map {
    line = $0
    sub(/#.*/, "", line)
    split(line, parts, /[[:space:]]+/)
    candidate = parts[2]
    if (candidate == "") candidate = parts[1]
    if (candidate == domain) next
  }
  { print }
' "$STREAM_CONF" > "$tmp_stream"
mv -f "$tmp_stream" "$STREAM_CONF"

tmp_stream="$(mktemp)"
UPSTREAM_NAME="$upstream_name" perl -0pe 'BEGIN { $name = $ENV{"UPSTREAM_NAME"}; } s/\nupstream\s+\Q$name\E\s*\{.*?\n\}\n//sg' "$STREAM_CONF" > "$tmp_stream" \
  || { rm -f "$tmp_stream"; die "perl failed to clean stale upstream block"; }
mv -f "$tmp_stream" "$STREAM_CONF"
cat >> "$STREAM_CONF" <<EOF

upstream $upstream_name {
    server 127.0.0.1:$BACKEND_PORT;
}
EOF

info "Validating nginx"
nginx -t

if command_exists systemctl; then
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
fi

public_url="https://$DOMAIN/sub/$TOKEN/combined.txt"
local_url="https://127.0.0.1:$BACKEND_PORT/sub/$TOKEN/combined.txt"

ok "NHM HTTPS subscription endpoint configured"
printf 'Public URL pattern: https://%s/sub/%s/<file>\n' "$DOMAIN" "$TOKEN"
printf 'Backup: %s\n' "$BACKUP_DIR"

if curl -k -fsS "$local_url" >/dev/null 2>&1; then
  ok "Local subscription test passed"
else
  warn "Local subscription test failed (token may not yet have generated files; run generate-profiles.sh first)"
fi

if curl -fsS "$public_url" >/dev/null 2>&1; then
  ok "Public subscription test passed"
else
  warn "Public subscription test failed (likely DNS not propagated yet); run: curl -i $public_url"
fi
