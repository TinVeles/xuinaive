#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${UPM_CONFIG_FILE:-$SCRIPT_DIR/config.env}"
ACCESS_ENV="${RIXXX_ACCESS_ENV:-/etc/rixxx-panel/access-info.env}"
RIXXX_CONFIG_JSON="${RIXXX_CONFIG_JSON:-/etc/rixxx-panel/config.json}"
CADDYFILE="${RIXXX_CADDYFILE:-/etc/caddy-naive/Caddyfile}"
MITA_STATE_FILE="${RIXXX_MITA_STATE_FILE:-/var/lib/rixxx-panel/mita-state.json}"
RIXXX_DB="${RIXXX_DB:-/var/lib/rixxx-panel/db.sqlite}"

DOMAIN=""
EMAIL=""
LISTEN=""
ASSUME_YES=0
SKIP_NGINX_ROUTE=0

usage() {
  cat <<'EOF'
Usage:
  sudo bash repair-rixxx-services.sh --yes
  sudo bash repair-rixxx-services.sh --domain naive.example.com --email admin@example.com --listen 127.0.0.1:9445 --yes

Repairs RIXXX Panel Naive/Mieru service layout for unified nginx:
- nginx owns public 443/tcp;
- caddy-naive listens only on the backend address, default 127.0.0.1:9445;
- RIXXX config.json is updated so the panel does not regenerate a public :443 Caddyfile;
- mita is started only when Mieru users exist.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && ${#1} -le 253 ]]
}

is_valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ && ${#1} -le 254 ]]
}

is_valid_hostport() {
  local host="${1%:*}" port="${1##*:}"
  [[ -n "$host" && "$host" != "$1" ]] || return 1
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^localhost$|^[A-Za-z0-9_.-]+$ ]] || return 1
  is_valid_port "$port"
}

config_value() {
  local key="$1" file
  for file in "$CONFIG_FILE" "$ACCESS_ENV"; do
    [[ -f "$file" ]] || continue
    awk -F= -v key="$key" '
      $1 == key {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
        print value
        exit
      }
    ' "$file"
  done | awk 'NF { print; exit }'
}

json_value() {
  local expr="$1"
  [[ -f "$RIXXX_CONFIG_JSON" ]] || return 1
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const v = $expr;
    if (v !== undefined && v !== null && String(v) !== '') process.stdout.write(String(v));
  " "$RIXXX_CONFIG_JSON"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --listen) LISTEN="${2:-}"; shift 2 ;;
    --skip-nginx-route) SKIP_NGINX_ROUTE=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this repair changes"
command -v node >/dev/null 2>&1 || die "node is required"

DOMAIN="${DOMAIN:-$(config_value RIXXX_DOMAIN || true)}"
DOMAIN="${DOMAIN:-$(config_value NH_PROXY_DOMAIN || true)}"
DOMAIN="${DOMAIN:-$(config_value NAIVE_DOMAIN || true)}"
DOMAIN="${DOMAIN:-$(json_value 'cfg.domain' || true)}"

EMAIL="${EMAIL:-$(config_value RIXXX_EMAIL || true)}"
EMAIL="${EMAIL:-$(config_value NH_EMAIL || true)}"
EMAIL="${EMAIL:-$(config_value NAIVE_EMAIL || true)}"
EMAIL="${EMAIL:-$(json_value 'cfg.adminEmail' || true)}"

LISTEN="${LISTEN:-$(config_value RIXXX_BACKEND_LISTEN || true)}"
LISTEN="${LISTEN:-$(config_value NH_BACKEND_LISTEN || true)}"
LISTEN="${LISTEN:-127.0.0.1:9445}"

[[ -n "$DOMAIN" ]] || die "Cannot determine RIXXX domain. Pass --domain."
[[ -n "$EMAIL" ]] || die "Cannot determine ACME email. Pass --email."
is_valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
is_valid_email "$EMAIL" || die "Invalid email: $EMAIL"
is_valid_hostport "$LISTEN" || die "Invalid listen host:port: $LISTEN"
[[ -f "$RIXXX_CONFIG_JSON" ]] || die "Missing $RIXXX_CONFIG_JSON. Is RIXXX Panel installed?"

listen_host="${LISTEN%:*}"
listen_port="${LISTEN##*:}"

info "Persisting RIXXX backend-only config: $DOMAIN -> $LISTEN"
DOMAIN="$DOMAIN" \
EMAIL="$EMAIL" \
LISTEN_HOST="$listen_host" \
LISTEN_PORT="$listen_port" \
RIXXX_CONFIG_JSON="$RIXXX_CONFIG_JSON" \
node <<'NODE'
const fs = require('fs');
const file = process.env.RIXXX_CONFIG_JSON || '/etc/rixxx-panel/config.json';
const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
cfg.domain = process.env.DOMAIN;
cfg.adminEmail = process.env.EMAIL;
cfg.naivePort = Number(process.env.LISTEN_PORT);
cfg.naivePublicPort = 443;
cfg.caddyBindHost = process.env.LISTEN_HOST || '127.0.0.1';
cfg.caddyBackendOnly = true;
cfg.caddyFile = '/etc/caddy-naive/Caddyfile';
cfg.caddyConfigDir = '/etc/caddy-naive';
cfg.caddyBin = cfg.caddyBin || '/usr/local/bin/caddy-naive';
cfg.fakeSiteDir = cfg.fakeSiteDir || '/var/www/fake-site';
cfg.mitaStateFile = cfg.mitaStateFile || '/var/lib/rixxx-panel/mita-state.json';
fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
NODE
chmod 0600 "$RIXXX_CONFIG_JSON" 2>/dev/null || true

if [[ "$SKIP_NGINX_ROUTE" != "1" && -f "$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh" ]]; then
  info "Ensuring nginx SNI route for RIXXX NaiveProxy"
  bash "$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh" --domain "$DOMAIN" --backend "$LISTEN" --name rixxx_naive
fi

info "Rewriting backend-only Caddyfile"
mkdir -p "$(dirname "$CADDYFILE")" /var/log/caddy-naive /var/www/fake-site
auth_lines=""
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$RIXXX_DB" ]]; then
  while IFS=$'\t' read -r username password; do
    [[ -n "$username" && -n "$password" ]] || continue
    [[ -z "$auth_lines" ]] || auth_lines+=$'\n'
    auth_lines+="                basic_auth $username $password"
  done < <(sqlite3 -separator $'\t' "$RIXXX_DB" "
    SELECT username, password
    FROM users
    WHERE COALESCE(username,'') <> ''
      AND COALESCE(password,'') <> ''
      AND (
        COALESCE(protocols,'') = ''
        OR COALESCE(protocols,'') LIKE '%naive%'
      )
    ORDER BY createdAt;
  " 2>/dev/null || true)
fi
if [[ -f "$CADDYFILE" ]]; then
  existing_auth_lines="$(awk '/^[[:space:]]*basic_auth[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+/ {print "                "$0}' "$CADDYFILE" | sed 's/^[[:space:]]*                /                /')"
  [[ -n "$auth_lines" ]] || auth_lines="$existing_auth_lines"
fi
if [[ -z "$auth_lines" ]]; then
  auth_lines="                basic_auth _placeholder_install _disabled_until_first_user"
fi

bind_line=""
if [[ "$listen_host" != "0.0.0.0" && "$listen_host" != "::" && "$listen_host" != "*" ]]; then
  bind_line="        bind $listen_host"
fi

cat > "$CADDYFILE" <<EOF
{
        order forward_proxy before file_server
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
        tls $EMAIL

        forward_proxy {
$auth_lines
                hide_ip
                hide_via
                probe_resistance
        }

        file_server {
                root /var/www/fake-site
        }
}
EOF

if getent group caddy >/dev/null 2>&1; then
  chown root:caddy "$CADDYFILE" 2>/dev/null || true
  chmod 0640 "$CADDYFILE" 2>/dev/null || true
else
  chmod 0644 "$CADDYFILE" 2>/dev/null || true
fi

if command -v caddy-naive >/dev/null 2>&1; then
  caddy-naive validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
  ok "Caddyfile is valid"
else
  warn "caddy-naive binary not found in PATH"
fi

systemctl reset-failed caddy-naive >/dev/null 2>&1 || true
systemctl enable caddy-naive >/dev/null 2>&1 || true
systemctl restart caddy-naive
systemctl is-active --quiet caddy-naive || {
  journalctl -u caddy-naive -n 80 --no-pager -l >&2 || true
  die "caddy-naive failed to start"
}
ok "caddy-naive is active on $LISTEN"

if [[ -f "$MITA_STATE_FILE" ]]; then
  mieru_users="$(node -e "
    const fs = require('fs');
    try {
      const s = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      process.stdout.write(String(Array.isArray(s.users) ? s.users.length : 0));
    } catch { process.stdout.write('0'); }
  " "$MITA_STATE_FILE")"
else
  mieru_users="0"
fi

if (( mieru_users > 0 )) && command -v mita >/dev/null 2>&1; then
  info "Reapplying mita config for $mieru_users Mieru user(s)"
  mita apply config "$MITA_STATE_FILE" >/dev/null 2>&1 || true
  systemctl reset-failed mita >/dev/null 2>&1 || true
  systemctl enable mita >/dev/null 2>&1 || true
  systemctl restart mita >/dev/null 2>&1 || mita start >/dev/null 2>&1 || true
  if systemctl is-active --quiet mita; then
    ok "mita is active"
  else
    warn "mita is still inactive; check: journalctl -u mita -n 80 --no-pager -l"
  fi
else
  systemctl disable --now mita >/dev/null 2>&1 || true
  systemctl reset-failed mita >/dev/null 2>&1 || true
  warn "mita left inactive: create at least one Mieru user in RIXXX Panel, then rebuild/restart"
fi

if command -v pm2 >/dev/null 2>&1; then
  pm2 restart panel-naive-mieru --update-env >/dev/null 2>&1 || true
fi

ok "RIXXX repair complete"
printf '\nChecks:\n'
printf '  systemctl status caddy-naive --no-pager -l\n'
printf '  systemctl status mita --no-pager -l\n'
printf "  ss -tlnp | grep -E ':(443|%s|2012)\\\\b'\n" "$listen_port"
