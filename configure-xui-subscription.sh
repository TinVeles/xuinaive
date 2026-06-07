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
# shellcheck disable=SC1091
source "$LIB_DIR/xui-routing.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DOMAIN="${XUI_SUB_DOMAIN:-}"
SUB_PORT="${XUI_SUB_PORT:-}"
SUB_PATH="${XUI_SUB_PATH:-}"
SUB_URI="${XUI_SUB_URI:-}"
SUB_ID="${XUI_SUB_ID:-}"
CLIENT_EMAIL="${XUI_SUB_CLIENT_EMAIL:-}"
BACKEND_PORT="${XUI_SUB_BACKEND_PORT:-9444}"
STREAM_CONF="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}"
ASSUME_YES=0
SHOW_ONLY=0
INTERACTIVE=0
ALLOW_REALITY_SNI_CONFLICT="${XUI_SUB_ALLOW_REALITY_SNI_CONFLICT:-0}"
REALITY_SNI="${XUI_REALITY_SNI:-}"
REALITY_TARGET="${XUI_REALITY_TARGET:-}"

usage() {
  cat <<EOF
Usage:
  sudo bash configure-xui-subscription.sh --show
  sudo bash configure-xui-subscription.sh --interactive
  sudo bash configure-xui-subscription.sh --domain SUB_DOMAIN --port SUB_PORT --path /SUB_PATH/ --sub-id SUB_ID --yes
  sudo bash configure-xui-subscription.sh --sub-port SUB_PORT --sub-path /SUB_PATH/ --sub-uri https://SUB_DOMAIN/SUB_PATH/ --sub-id SUB_ID --yes

What it does:
  - updates x-ui subscription settings: subPort, subPath, subURI
  - can update a latest-line 3x-ui client sub_id when --client-email is provided
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
  --uri URL                public subscription base URI, for example https://sub.example.com/path/
  --sub-port PORT          alias for --port
  --sub-path /PATH/        alias for --path
  --sub-uri URL            alias for --uri
  --sub-id ID              test subscription id
  --client-email EMAIL     latest-line 3x-ui client email whose sub_id should become --sub-id
  --backend-port PORT      local nginx HTTPS backend port, default: ${BACKEND_PORT}
  --xui-db PATH            x-ui sqlite DB, default: ${XUI_DB}
  --show                   print current x-ui subscription settings and clients, then exit
  --interactive            prompt for values in the terminal
  --reality-sni DOMAIN     move non-WARP Reality serverNames to DOMAIN before configuring subscription
  --reality-target HOST:PORT
                           Reality target when --reality-sni is used; default DOMAIN:443
  --allow-reality-sni-conflict
                           allow DOMAIN to appear in Reality serverNames anyway
  --yes                    apply changes
EOF
}

setting_get() {
  local key="$1"
  sqlite3 -readonly "$XUI_DB" "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" 2>/dev/null || true
}

first_client_email() {
  sqlite3 -readonly "$XUI_DB" "
    SELECT email
    FROM clients
    WHERE COALESCE(email,'') <> ''
    ORDER BY id
    LIMIT 1;
  " 2>/dev/null || true
}

first_client_sub_id() {
  sqlite3 -readonly "$XUI_DB" "
    SELECT COALESCE(NULLIF(sub_id,''), email)
    FROM clients
    WHERE COALESCE(email,'') <> ''
    ORDER BY id
    LIMIT 1;
  " 2>/dev/null || true
}

show_current_subscription() {
  local current_port current_path current_uri current_enable
  current_port="$(setting_get subPort)"
  current_path="$(setting_get subPath)"
  current_uri="$(setting_get subURI)"
  current_enable="$(setting_get subEnable)"

  printf 'Current x-ui subscription settings\n'
  printf '%s\n' '----------------------------------'
  printf 'subEnable|%s\n' "${current_enable:-<empty>}"
  printf 'subPort|%s\n' "${current_port:-<empty>}"
  printf 'subPath|%s\n' "${current_path:-<empty>}"
  printf 'subURI|%s\n' "${current_uri:-<empty>}"
  printf '\n'

  if sqlite3 -readonly "$XUI_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='clients' LIMIT 1;" 2>/dev/null | grep -q 1; then
    printf 'Latest-line 3x-ui clients\n'
    printf '%s\n' '-------------------------'
    sqlite3 -readonly -separator '|' "$XUI_DB" "
      SELECT id, email, COALESCE(sub_id,'')
      FROM clients
      ORDER BY id
      LIMIT 50;
    " 2>/dev/null || true
    printf '\n'
  fi
}

prompt_keep() {
  local var_name="$1" prompt="$2" current_value="${3:-}" input
  if [[ -n "$current_value" ]]; then
    read -r -p "$prompt [$current_value]: " input
    input="${input:-$current_value}"
  else
    while [[ -z "${input:-}" ]]; do
      read -r -p "$prompt: " input
    done
  fi
  printf -v "$var_name" '%s' "$input"
}

configure_interactive() {
  local current_port current_path current_uri current_domain current_sub_id current_email reply
  current_port="$(setting_get subPort)"
  current_path="$(setting_get subPath)"
  current_uri="$(setting_get subURI)"
  current_sub_id="$(first_client_sub_id)"
  current_email="$(first_client_email)"

  if [[ -n "$current_uri" && "$current_uri" == https://*/* ]]; then
    local uri_rest="${current_uri#https://}"
    current_domain="${uri_rest%%/*}"
  else
    current_domain="$DOMAIN"
  fi

  show_current_subscription
  prompt_keep DOMAIN "Subscription domain" "$current_domain"
  prompt_keep SUB_PORT "x-ui subscription service port" "${current_port:-$SUB_PORT}"
  prompt_keep SUB_PATH "Subscription URI path, must start and end with /" "${current_path:-$SUB_PATH}"
  [[ "$SUB_PATH" == /* ]] || SUB_PATH="/$SUB_PATH"
  [[ "$SUB_PATH" == */ ]] || SUB_PATH="$SUB_PATH/"
  SUB_URI="https://$DOMAIN$SUB_PATH"
  prompt_keep SUB_ID "Subscription id for test URL" "${SUB_ID:-$current_sub_id}"
  read -r -p "Client email to update sub_id to '$SUB_ID' (blank to skip${current_email:+, for example $current_email}): " CLIENT_EMAIL
  CLIENT_EMAIL="${CLIENT_EMAIL:-}"
  prompt_keep BACKEND_PORT "Local nginx backend port" "$BACKEND_PORT"

  if [[ "$ASSUME_YES" != "1" ]]; then
    printf '\nWill configure: %s%s\n' "$SUB_URI" "$SUB_ID"
    if [[ -n "$CLIENT_EMAIL" ]]; then
      printf 'Will set clients.sub_id=%s where email=%s\n' "$SUB_ID" "$CLIENT_EMAIL"
    fi
    read -r -p "Type APPLY to continue: " reply
    [[ "$reply" == "APPLY" ]] || die "Cancelled"
    ASSUME_YES=1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --port) SUB_PORT="${2:-}"; shift 2 ;;
    --path) SUB_PATH="${2:-}"; shift 2 ;;
    --uri) SUB_URI="${2:-}"; shift 2 ;;
    --sub-port) SUB_PORT="${2:-}"; shift 2 ;;
    --sub-path) SUB_PATH="${2:-}"; shift 2 ;;
    --sub-uri) SUB_URI="${2:-}"; shift 2 ;;
    --sub-id) SUB_ID="${2:-}"; shift 2 ;;
    --client-email) CLIENT_EMAIL="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --show) SHOW_ONLY=1; shift ;;
    --interactive) INTERACTIVE=1; shift ;;
    --reality-sni) REALITY_SNI="${2:-}"; shift 2 ;;
    --reality-target) REALITY_TARGET="${2:-}"; shift 2 ;;
    --allow-reality-sni-conflict) ALLOW_REALITY_SNI_CONFLICT=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
command_exists sqlite3 || die "sqlite3 is required"
[[ -f "$XUI_DB" ]] || die "x-ui database not found: $XUI_DB"

if [[ "$SHOW_ONLY" == "1" ]]; then
  show_current_subscription
  exit 0
fi

if [[ "$INTERACTIVE" == "1" ]]; then
  configure_interactive
fi

[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes, or use --interactive"

if [[ -n "$SUB_URI" ]]; then
  [[ "$SUB_URI" =~ ^https://[^/]+/.+ ]] || die "--uri/--sub-uri must look like https://domain/path/"
  uri_rest="${SUB_URI#https://}"
  uri_domain="${uri_rest%%/*}"
  uri_path="/${uri_rest#*/}"
  [[ -n "$DOMAIN" ]] || DOMAIN="$uri_domain"
  [[ -n "$SUB_PATH" ]] || SUB_PATH="$uri_path"
fi

[[ -n "$DOMAIN" ]] || die "--domain is required, or provide --sub-uri"
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid domain: $DOMAIN"
[[ -n "$SUB_PORT" ]] || die "--port is required"
[[ "$SUB_PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "--backend-port must be numeric"
case "$BACKEND_PORT" in
  443|7443|8443|9443|9445)
    die "--backend-port $BACKEND_PORT conflicts with x-ui/nginx ingress ports; use an unused local backend port, for example 9444"
    ;;
esac
[[ -n "$SUB_PATH" ]] || die "--path is required"
[[ "$SUB_PATH" == /*/ ]] || die "--path must start and end with /"
[[ "$SUB_PATH" != *"'"* ]] || die "--path must not contain single quote"
[[ -n "$SUB_URI" ]] || SUB_URI="https://$DOMAIN$SUB_PATH"
[[ "$SUB_URI" == */ ]] || die "--uri/--sub-uri must end with /"
[[ "$SUB_URI" == "https://$DOMAIN"* ]] || die "--uri/--sub-uri domain must match --domain"
[[ "$SUB_URI" == "https://$DOMAIN$SUB_PATH" ]] || die "--uri/--sub-uri must equal https://DOMAIN/PATH/ from --domain and --path"
[[ -n "$SUB_ID" ]] || die "--sub-id is required for the post-change test"
[[ "$SUB_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--sub-id may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
if [[ -n "$CLIENT_EMAIL" ]]; then
  [[ "$CLIENT_EMAIL" =~ ^[A-Za-z0-9_.@+-]+$ ]] || die "--client-email may contain only A-Z, a-z, 0-9, dot, underscore, plus, at, and dash"
fi
command_exists nginx || die "nginx is required"

if [[ -n "$REALITY_SNI" ]]; then
  [[ "$REALITY_SNI" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid --reality-sni: $REALITY_SNI"
  [[ -n "$REALITY_TARGET" ]] || REALITY_TARGET="$REALITY_SNI:443"
  info "Moving non-WARP Reality SNI to $REALITY_SNI"
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET stream_settings = json_set(
      stream_settings,
      '$.realitySettings.serverNames',
      json_array($(sql_quote "$REALITY_SNI")),
      '$.realitySettings.target',
      $(sql_quote "$REALITY_TARGET"),
      '$.realitySettings.settings.serverName',
      ''
    )
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='tcp'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
  "
fi

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
sub_uri="$SUB_URI"
public_url="${SUB_URI}${SUB_ID}"
local_url="https://127.0.0.1:${SUB_PORT}${SUB_PATH}${SUB_ID}"

info "Removing stale manual subscription nginx configs"
for stale_dir in /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/sites-available "$SITES_DIR"; do
  [[ -d "$stale_dir" ]] || continue
  for stale_conf in \
    "$stale_dir/xui-subscription.conf" \
    "$stale_dir/upm-xui-subscription-$DOMAIN.conf" \
    "$stale_dir/00-subscription-$DOMAIN.conf" \
    "$stale_dir/00-subscription-sub.$DOMAIN.conf" \
    "$stale_dir/$DOMAIN.bak" \
    "$stale_dir/$DOMAIN.old" \
    "$stale_dir/$DOMAIN.orig" \
    "$stale_dir/$DOMAIN.save" \
    "$stale_dir/$DOMAIN.disabled"; do
    [[ -e "$stale_conf" || -L "$stale_conf" ]] || continue
    rm -f -- "$stale_conf"
  done
done
xui_disable_nginx_enabled_backup_configs

info "Updating x-ui subscription settings"
upm_sqlite_setting_set "$XUI_DB" "subPort" "$SUB_PORT"
upm_sqlite_setting_set "$XUI_DB" "subPath" "$SUB_PATH"
upm_sqlite_setting_set "$XUI_DB" "subURI" "$sub_uri"
upm_sqlite_setting_set "$XUI_DB" "subEnable" "true"

if [[ -n "$CLIENT_EMAIL" ]]; then
  info "Updating latest-line 3x-ui client sub_id: $CLIENT_EMAIL -> $SUB_ID"
  changed="$(sqlite3 "$XUI_DB" "
    UPDATE clients
    SET sub_id=$(sql_quote "$SUB_ID")
    WHERE email=$(sql_quote "$CLIENT_EMAIL");
    SELECT changes();
  " 2>/dev/null || printf '0')"
  [[ "${changed:-0}" != "0" ]] || die "No v3 client found with email=$CLIENT_EMAIL"
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET settings = json_set(
      settings,
      '$.clients',
      (
        SELECT json_group_array(
          CASE
            WHEN json_extract(value,'$.email')=$(sql_quote "$CLIENT_EMAIL")
            THEN json_set(value,'$.subId',$(sql_quote "$SUB_ID"))
            ELSE value
          END
        )
        FROM json_each(settings,'$.clients')
      )
    )
    WHERE json_valid(settings)=1
      AND EXISTS (
        SELECT 1
        FROM json_each(settings,'$.clients')
        WHERE json_extract(value,'$.email')=$(sql_quote "$CLIENT_EMAIL")
      );
  "
fi

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
xui_ensure_nginx_reality_sni_routes

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
