#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/common.sh"

DOMAIN=""
EMAIL=""
LISTEN="127.0.0.1:9445"
PANEL_ACCESS="ssh-tunnel"
PANEL_PUBLIC_PORT="8081"
ADMIN_USER="${RIXXX_ADMIN_USER:-admin}"
ADMIN_PASS="${RIXXX_ADMIN_PASS:-}"
MIERU_START="${RIXXX_MIERU_START:-2012}"
MIERU_END="${RIXXX_MIERU_END:-2022}"
FAKE_SITE_URL="${RIXXX_FAKE_SITE_URL:-https://www.example.com}"
PROBE_SECRET="${RIXXX_PROBE_SECRET:-}"
PROBE_MODE="${RIXXX_PROBE_MODE:-bare}"
TLS_CERT=""
TLS_KEY=""

RIXXX_REPO_URL="${RIXXX_REPO_URL:-https://github.com/cwash797-cmd/Panel-Naive-Mieru-by-RIXXX}"
RIXXX_REPO_REF="${RIXXX_REPO_REF:-c1955dd917460e7275ba28109893fdd4b6cdc560}"
RIXXX_SRC_DIR="${RIXXX_SRC_DIR:-/opt/upm-rixxx-panel-src}"
LOCAL_NM_PANEL_DIR="${LOCAL_NM_PANEL_DIR:-$PROJECT_DIR/components/nm-panel}"
CONFIG_FILE="$PROJECT_DIR/config.env"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified-backend.sh --domain naive.example.com --email admin@example.com [--listen 127.0.0.1:9445]

Installs RIXXX Panel Naive + Mieru as backend for the unified nginx SNI layout:
- nginx owns public 443/tcp;
- caddy-naive serves NaiveProxy on the backend port;
- Mieru uses its own public TCP/UDP port range;
- panel-naive-mieru runs on 127.0.0.1:3000 by default.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && ${#1} -le 253 ]]
}

is_valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ && ${#1} -le 254 ]]
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

is_valid_hostport() {
  local host="${1%:*}" port="${1##*:}"
  [[ -n "$host" && "$host" != "$1" ]] || return 1
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^localhost$|^[A-Za-z0-9_.-]+$ ]] || return 1
  is_valid_port "$port"
}

random_pass() {
  openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

wait_http() {
  local url="$1" label="$2" attempts="${3:-40}" delay="${4:-1}"
  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 3 "$url" >/dev/null; then
      ok "$label responds: $url"
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

require_active() {
  local svc="$1"
  if ! systemctl is-active --quiet "$svc"; then
    printf 'ERROR: %s failed to start\n' "$svc" >&2
    journalctl -u "$svc" -n 80 --no-pager -l >&2 || true
    exit 1
  fi
  ok "$svc is active"
}

stop_old_RIXXX() {
  local svc
  for svc in caddy-naive mita; do
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  if command -v pm2 >/dev/null 2>&1; then
    pm2 delete panel-naive-mieru >/dev/null 2>&1 || true
  fi
}

backup_state() {
  local backup_dir path
  backup_dir="/opt/unified-proxy-manager/backups/rixxx-panel-$(date '+%Y-%m-%d-%H-%M-%S')"
  mkdir -p "$backup_dir"
  for path in \
    /etc/caddy-naive /etc/rixxx-panel /opt/panel-naive-mieru /var/lib/rixxx-panel \
    /etc/systemd/system/caddy-naive.service \
    /etc/systemd/system/mita.service /etc/nginx/sites-enabled/panel-naive-mieru \
    /etc/nginx/sites-available/panel-naive-mieru /etc/nginx/sites-enabled/panel-naive-mieru \
    /etc/nginx/sites-available/panel-naive-mieru; do
    if [[ -e "$path" || -L "$path" ]]; then
      mkdir -p "$backup_dir$(dirname "$path")"
      cp -aT "$path" "$backup_dir$path"
    fi
  done
  ok "Backup directory: $backup_dir"
}

prepare_upstream() {
  local work_dir="$1"
  if [[ -d "$LOCAL_NM_PANEL_DIR/panel" && -f "$LOCAL_NM_PANEL_DIR/install.sh" ]]; then
    info "Using bundled NM panel source: $LOCAL_NM_PANEL_DIR"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    cp -a "$LOCAL_NM_PANEL_DIR"/. "$work_dir"/
  elif [[ -d "$RIXXX_SRC_DIR/.git" ]]; then
    info "Updating RIXXX source: $RIXXX_SRC_DIR"
    git -C "$RIXXX_SRC_DIR" fetch --tags --force origin
    git -C "$RIXXX_SRC_DIR" checkout --force "$RIXXX_REPO_REF"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    cp -a "$RIXXX_SRC_DIR"/. "$work_dir"/
  else
    rm -rf "$RIXXX_SRC_DIR"
    info "Cloning RIXXX source: $RIXXX_REPO_URL"
    git clone "$RIXXX_REPO_URL" "$RIXXX_SRC_DIR"
    git -C "$RIXXX_SRC_DIR" checkout --force "$RIXXX_REPO_REF"
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    cp -a "$RIXXX_SRC_DIR"/. "$work_dir"/
  fi

  # Upstream non-interactive mode resets UFW. Unified installer must not wipe
  # user firewall state, so disable upstream UFW and add narrow rules below.
  if grep -q 'USE_UFW="Y"' "$work_dir/install.sh"; then
    sed -i 's/USE_UFW="Y"/USE_UFW="N"/' "$work_dir/install.sh"
  else
    warn "RIXXX installer UFW marker not found; firewall reset guard was not patched"
  fi
}

configure_panel_proxy() {
  [[ "$PANEL_ACCESS" != "nginx8080" && "$PANEL_ACCESS" != "public" ]] && return 0
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > /etc/nginx/sites-available/panel-naive-mieru <<EOF
server {
    listen ${PANEL_PUBLIC_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  ln -sf /etc/nginx/sites-available/panel-naive-mieru /etc/nginx/sites-enabled/panel-naive-mieru
  rm -f /etc/nginx/sites-enabled/panel-naive-mieru /etc/nginx/sites-available/panel-naive-mieru
  nginx -t || die "nginx config test failed after panel proxy creation"
  systemctl reload nginx || systemctl restart nginx || true
  wait_http "http://127.0.0.1:${PANEL_PUBLIC_PORT}/" "RIXXX panel nginx proxy" 40 1 || die "RIXXX panel proxy is not responding"
}

configure_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow 80/tcp comment "ACME HTTP-01" >/dev/null 2>&1 || true
  ufw allow 443/tcp comment "Unified nginx TLS" >/dev/null 2>&1 || true
  ufw allow "${MIERU_START}:${MIERU_END}/tcp" comment "Mieru TCP" >/dev/null 2>&1 || true
  ufw allow "${MIERU_START}:${MIERU_END}/udp" comment "Mieru UDP" >/dev/null 2>&1 || true
  if [[ "$PANEL_ACCESS" == "nginx8080" || "$PANEL_ACCESS" == "public" ]]; then
    ufw allow "${PANEL_PUBLIC_PORT}/tcp" comment "RIXXX panel" >/dev/null 2>&1 || true
  fi
}

fix_caddy_backend_listener() {
  local caddyfile="/etc/caddy-naive/Caddyfile"
  local listen_host="${LISTEN%:*}" listen_port="${LISTEN##*:}"
  local auth_user auth_pass bind_line
  [[ -f "$caddyfile" ]] || return 0

  auth_user="$(awk '/^[[:space:]]*basic_auth[[:space:]]/ {print $2; exit}' "$caddyfile")"
  auth_pass="$(awk '/^[[:space:]]*basic_auth[[:space:]]/ {print $3; exit}' "$caddyfile")"
  [[ -n "$auth_user" ]] || auth_user="_placeholder_install"
  [[ -n "$auth_pass" ]] || auth_pass="$ADMIN_PASS"

  bind_line=""
  if [[ -n "$listen_host" && "$listen_host" != "0.0.0.0" && "$listen_host" != "::" && "$listen_host" != "*" ]]; then
    bind_line="        bind $listen_host"
  fi

  tls_line="        tls $EMAIL"
  cert_file="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  key_file="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    tls_line="        tls $cert_file $key_file"
  fi

  cat > "$caddyfile" <<EOF
{
        order forward_proxy before file_server
        auto_https disable_redirects
        servers {
                protocols h1 h2
        }
        email $EMAIL
        admin off
        log {
                output file /var/log/caddy-naive/access.log {
                        roll_size 50mb
                        roll_keep_for 720h
                }
                format json
        }
}

$DOMAIN:$listen_port {
$bind_line
$tls_line

        forward_proxy {
                basic_auth $auth_user $auth_pass
                hide_ip
                hide_via
                probe_resistance
        }

        file_server {
                root /var/www/fake-site
        }
}
EOF
}

fix_rixxx_backend_config() {
  local config_json="/etc/rixxx-panel/config.json"
  local listen_host="${LISTEN%:*}" listen_port="${LISTEN##*:}"
  [[ -f "$config_json" ]] || return 0

  DOMAIN="$DOMAIN" \
  EMAIL="$EMAIL" \
  LISTEN_HOST="$listen_host" \
  LISTEN_PORT="$listen_port" \
  MIERU_START="$MIERU_START" \
  MIERU_END="$MIERU_END" \
  node <<'NODE'
const fs = require('fs');
const file = '/etc/rixxx-panel/config.json';
const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
cfg.domain = process.env.DOMAIN;
cfg.adminEmail = process.env.EMAIL || cfg.adminEmail || '';
cfg.naivePort = Number(process.env.LISTEN_PORT);
cfg.naivePublicPort = 443;
cfg.caddyBindHost = process.env.LISTEN_HOST || '127.0.0.1';
cfg.caddyBackendOnly = true;
cfg.caddyFile = '/etc/caddy-naive/Caddyfile';
cfg.caddyConfigDir = '/etc/caddy-naive';
cfg.caddyBin = cfg.caddyBin || '/usr/local/bin/caddy-naive';
cfg.mieruPortStart = Number(process.env.MIERU_START || cfg.mieruPortStart || 2012);
cfg.mieruPortEnd = Number(process.env.MIERU_END || cfg.mieruPortEnd || 2022);
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
NODE
  chmod 0600 "$config_json" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --listen) LISTEN="${2:-}"; shift 2 ;;
    --panel-access) PANEL_ACCESS="${2:-}"; shift 2 ;;
    --panel-public-port) PANEL_PUBLIC_PORT="${2:-}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --admin-pass) ADMIN_PASS="${2:-}"; shift 2 ;;
    --mieru-start) MIERU_START="${2:-}"; shift 2 ;;
    --mieru-end) MIERU_END="${2:-}"; shift 2 ;;
    --fake-site-url) FAKE_SITE_URL="${2:-}"; shift 2 ;;
    --probe-secret) PROBE_SECRET="${2:-}"; shift 2 ;;
    --probe-mode) PROBE_MODE="${2:-}"; shift 2 ;;
    --tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key) TLS_KEY="${2:-}"; shift 2 ;;
    --with-mieru|--enable-mieru) shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$EMAIL" ]] || die "--email is required"
is_valid_domain "$DOMAIN" || die "--domain is invalid: $DOMAIN"
is_valid_email "$EMAIL" || die "--email is invalid: $EMAIL"
is_valid_hostport "$LISTEN" || die "--listen must be safe host:port"
is_valid_port "$PANEL_PUBLIC_PORT" || die "--panel-public-port must be 1..65535"
is_valid_port "$MIERU_START" || die "--mieru-start must be 1..65535"
is_valid_port "$MIERU_END" || die "--mieru-end must be 1..65535"
(( MIERU_END >= MIERU_START )) || die "--mieru-end must be >= --mieru-start"
[[ -z "$TLS_CERT$TLS_KEY" ]] || warn "RIXXX installer manages Caddy/ACME itself; --tls-cert/--tls-key ignored"
[[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(random_pass)"
[[ -n "$PROBE_SECRET" ]] || PROBE_SECRET="$(openssl rand -hex 16)"

NAIVE_PORT="${LISTEN##*:}"
WORK_DIR="$(mktemp -d /tmp/upm-rixxx-panel.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

backup_state
stop_old_RIXXX
prepare_upstream "$WORK_DIR"

info "Installing RIXXX Panel Naive + Mieru"
bash "$WORK_DIR/install.sh" \
  --non-interactive \
  --force \
  --domain "$DOMAIN" \
  --email "$EMAIL" \
  --admin-user "$ADMIN_USER" \
  --admin-pass "$ADMIN_PASS" \
  --naive-port "$NAIVE_PORT" \
  --public-naive-port 443 \
  --bind-host "${LISTEN%:*}" \
  --backend-only \
  --mieru-start "$MIERU_START" \
  --mieru-end "$MIERU_END" \
  --fake-site-url "$FAKE_SITE_URL" \
  --probe-secret "$PROBE_SECRET" \
  --probe-mode "$PROBE_MODE" \
  --lang ru

fix_rixxx_backend_config
fix_caddy_backend_listener
systemctl reset-failed caddy-naive >/dev/null 2>&1 || true
systemctl restart caddy-naive || true
require_active caddy-naive
if systemctl is-active --quiet mita; then
  ok "mita is active"
else
  warn "mita is not active yet; RIXXX starts it after first Mieru user is created"
fi

if command -v pm2 >/dev/null 2>&1; then
  pm2 describe panel-naive-mieru >/dev/null 2>&1 || die "PM2 process panel-naive-mieru is missing"
  ok "panel-naive-mieru PM2 process exists"
fi
wait_http "http://127.0.0.1:3000/" "RIXXX panel" 50 1 || die "RIXXX panel is not responding on 127.0.0.1:3000"

configure_panel_proxy
configure_firewall

upm_config_set_many "$CONFIG_FILE" \
  NH_BACKEND_KIND "rixxx-naive-mieru" \
  RIXXX_DOMAIN "$DOMAIN" \
  RIXXX_EMAIL "$EMAIL" \
  RIXXX_BACKEND_LISTEN "$LISTEN" \
  RIXXX_ACCESS "$PANEL_ACCESS" \
  NH_PROXY_DOMAIN "$DOMAIN" \
  NAIVE_DOMAIN "$DOMAIN" \
  NH_EMAIL "$EMAIL" \
  NH_BACKEND_LISTEN "$LISTEN" \
  NH_PANEL_URL "http://127.0.0.1:3000/" \
  NH_PANEL_LOGIN "$ADMIN_USER" \
  NH_PANEL_PASSWORD "$ADMIN_PASS" \
  RIXXX_PANEL_URL "http://127.0.0.1:3000/" \
  RIXXX_PANEL_LOGIN "$ADMIN_USER" \
  RIXXX_PANEL_PASSWORD "$ADMIN_PASS" \
  NH_ENABLE_MIERU "1" \
  RIXXX_PANEL_DIR "/opt/panel-naive-mieru" \
  RIXXX_DB "/var/lib/rixxx-panel/db.sqlite" \
  RIXXX_MIERU_PORT_START "$MIERU_START" \
  RIXXX_MIERU_PORT_END "$MIERU_END" \
  RIXXX_PROBE_SECRET "$PROBE_SECRET" \
  RIXXX_REPO_URL "$RIXXX_REPO_URL" \
  RIXXX_REPO_REF "$RIXXX_REPO_REF"

mkdir -p /etc/rixxx-panel
upm_config_set_many /etc/rixxx-panel/access-info.env \
  NH_BACKEND_KIND "rixxx-naive-mieru" \
  NH_PANEL_URL "http://127.0.0.1:3000/" \
  NH_PANEL_LOGIN "$ADMIN_USER" \
  NH_PANEL_PASSWORD "$ADMIN_PASS" \
  RIXXX_PANEL_URL "http://127.0.0.1:3000/" \
  RIXXX_PANEL_LOGIN "$ADMIN_USER" \
  RIXXX_PANEL_PASSWORD "$ADMIN_PASS" \
  RIXXX_PANEL_DIR "/opt/panel-naive-mieru" \
  RIXXX_DOMAIN "$DOMAIN" \
  RIXXX_BACKEND_LISTEN "$LISTEN"
chmod 0600 /etc/rixxx-panel/access-info.env 2>/dev/null || true

ok "RIXXX Panel Naive + Mieru installed"
