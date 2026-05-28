#!/usr/bin/env bash
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

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DOMAIN="${XUI_SUB_DOMAIN:-}"
SUB_PORT="${XUI_SUB_PORT:-}"
SUB_PATH="${XUI_SUB_PATH:-}"
SUB_ID="${XUI_SUB_ID:-}"
BACKEND_PORT="${XUI_SUB_BACKEND_PORT:-9444}"
STREAM_CONF="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}"
ASSUME_YES=0
ALLOW_REALITY_SNI_CONFLICT="${XUI_SUB_ALLOW_REALITY_SNI_CONFLICT:-0}"

usage() {
  cat <<EOF
Usage:
  sudo bash configure-xui-subscription.sh --domain SUB_DOMAIN --port SUB_PORT --path /SUB_PATH/ --sub-id SUB_ID --yes

What it does:
  - updates x-ui subscription settings: subPort, subPath, subURI
  - creates a dedicated nginx HTTPS backend on 127.0.0.1:${BACKEND_PORT}
  - maps the public subscription SNI/domain in nginx stream to that backend
  - reloads nginx and x-ui

Important:
  The subscription domain must not be used as a Reality SNI/serverName.
  If both use the same SNI, nginx stream routes Reality clients to the subscription backend.

Options:
  --domain DOMAIN          public subscription domain
  --port PORT              x-ui subscription port
  --path /PATH/            x-ui subscription path
  --sub-id ID              test subscription id
  --backend-port PORT      local nginx HTTPS backend port, default: ${BACKEND_PORT}
  --xui-db PATH            x-ui sqlite DB, default: ${XUI_DB}
  --allow-reality-sni-conflict
                           allow DOMAIN to appear in Reality serverNames anyway
  --yes                    apply changes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --port) SUB_PORT="${2:-}"; shift 2 ;;
    --path) SUB_PATH="${2:-}"; shift 2 ;;
    --sub-id) SUB_ID="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --allow-reality-sni-conflict) ALLOW_REALITY_SNI_CONFLICT=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid domain: $DOMAIN"
[[ -n "$SUB_PORT" ]] || die "--port is required"
[[ "$SUB_PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "--backend-port must be numeric"
[[ -n "$SUB_PATH" ]] || die "--path is required"
[[ "$SUB_PATH" == /*/ ]] || die "--path must start and end with /"
[[ "$SUB_PATH" != *"'"* ]] || die "--path must not contain single quote"
[[ -n "$SUB_ID" ]] || die "--sub-id is required for the post-change test"
[[ "$SUB_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--sub-id may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
command_exists sqlite3 || die "sqlite3 is required"
command_exists nginx || die "nginx is required"
[[ -f "$XUI_DB" ]] || die "x-ui database not found: $XUI_DB"

reality_sni_conflicts="$(sqlite3 -readonly "$XUI_DB" "
  SELECT COUNT(*)
  FROM inbounds
  WHERE json_valid(stream_settings)=1
    AND json_extract(stream_settings,'$.security')='reality'
    AND (
      json_extract(stream_settings,'$.realitySettings.settings.serverName')=$(sql_quote "$DOMAIN")
      OR EXISTS (
        SELECT 1
        FROM json_each(json_extract(stream_settings,'$.realitySettings.serverNames'))
        WHERE value=$(sql_quote "$DOMAIN")
      )
    );
" 2>/dev/null || printf '0')"
reality_sni_conflicts="${reality_sni_conflicts:-0}"
if [[ "$reality_sni_conflicts" != "0" && "$ALLOW_REALITY_SNI_CONFLICT" != "1" ]]; then
  die "Subscription domain $DOMAIN is used by $reality_sni_conflicts Reality inbound(s). Change Reality SNI/serverName first, or rerun with --allow-reality-sni-conflict if you intentionally want this."
fi

CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
CERT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
[[ -f "$CERT_FILE" && -f "$CERT_KEY" ]] || die "TLS cert for $DOMAIN not found in /etc/letsencrypt/live/$DOMAIN"

mkdir -p /opt/unified-proxy-manager/backups
BACKUP_DIR="/opt/unified-proxy-manager/backups/xui-subscription-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$BACKUP_DIR"
for path in "$XUI_DB" "$STREAM_CONF" "$SITES_DIR"; do
  [[ -e "$path" || -L "$path" ]] || continue
  mkdir -p "$BACKUP_DIR$(dirname "$path")"
  cp -a "$path" "$BACKUP_DIR$(dirname "$path")/"
done

safe_name="$(printf '%s' "$DOMAIN" | tr -c 'A-Za-z0-9' '_')"
upstream_name="upm_${safe_name}_sub"
backend_conf="$SITES_DIR/upm-xui-subscription-$DOMAIN.conf"
sub_uri="https://$DOMAIN$SUB_PATH"
public_url="${sub_uri}${SUB_ID}"
local_url="https://127.0.0.1:${SUB_PORT}${SUB_PATH}${SUB_ID}"

info "Removing stale manual subscription nginx configs"
for stale_conf in \
  "/etc/nginx/conf.d/xui-subscription.conf" \
  "$SITES_DIR/00-subscription-$DOMAIN.conf" \
  "$SITES_DIR/00-subscription-sub.$DOMAIN.conf"; do
  [[ -e "$stale_conf" || -L "$stale_conf" ]] || continue
  rm -f "$stale_conf"
done

info "Updating x-ui subscription settings"
sqlite3 "$XUI_DB" "
  INSERT INTO settings (key, value) VALUES ('subPort', $(sql_quote "$SUB_PORT"))
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  INSERT INTO settings (key, value) VALUES ('subPath', $(sql_quote "$SUB_PATH"))
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  INSERT INTO settings (key, value) VALUES ('subURI', $(sql_quote "$sub_uri"))
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  INSERT INTO settings (key, value) VALUES ('subEnable', 'true')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
" 2>/dev/null || sqlite3 "$XUI_DB" "
  UPDATE settings SET value=$(sql_quote "$SUB_PORT") WHERE key='subPort';
  UPDATE settings SET value=$(sql_quote "$SUB_PATH") WHERE key='subPath';
  UPDATE settings SET value=$(sql_quote "$sub_uri") WHERE key='subURI';
  UPDATE settings SET value='true' WHERE key='subEnable';
"

info "Writing nginx subscription backend: $backend_conf"
cat > "$backend_conf" <<EOF
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

    location $SUB_PATH {
        proxy_pass https://127.0.0.1:$SUB_PORT$SUB_PATH;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        return 404;
    }
}
EOF

mkdir -p "$(dirname "$STREAM_CONF")"
if [[ ! -f "$STREAM_CONF" ]]; then
  cat > "$STREAM_CONF" <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    $DOMAIN $upstream_name;
    default xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen 443;
    listen [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF
fi

info "Updating nginx stream route for $DOMAIN -> $upstream_name"
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
  systemctl restart x-ui 2>/dev/null || true
fi

ok "x-ui subscription URL configured: $public_url"
printf 'Reality SNI note: keep Reality serverName/SNI different from %s.\n' "$DOMAIN"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf 'Local test:  curl -k -i %s\n' "$local_url"
printf 'Public test: curl -i %s\n' "$public_url"

if curl -k -fsS "$local_url" >/dev/null 2>&1; then
  ok "Local x-ui subscription test passed"
else
  warn "Local x-ui subscription test failed; check that subId exists: $SUB_ID"
fi

if curl -fsS "$public_url" >/dev/null 2>&1; then
  ok "Public subscription test passed"
else
  warn "Public subscription test failed; run: curl -i $public_url"
fi
