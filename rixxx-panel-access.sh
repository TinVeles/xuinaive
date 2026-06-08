#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${UPM_CONFIG_FILE:-$SCRIPT_DIR/config.env}"
RIXXX_CONFIG_JSON="${RIXXX_CONFIG_JSON:-/etc/rixxx-panel/config.json}"
RIXXX_ACCESS_ENV="${RIXXX_ACCESS_ENV:-/etc/rixxx-panel/access-info.env}"

RESET_PASSWORD=0
NEW_PASSWORD=""
NEW_LOGIN=""
REDACT="${UPM_REDACT_SECRETS:-0}"

usage() {
  cat <<'EOF'
Usage:
  sudo bash rixxx-panel-access.sh
  sudo bash rixxx-panel-access.sh --reset-password
  sudo bash rixxx-panel-access.sh --reset-password 'NewStrongPassword'
  sudo bash rixxx-panel-access.sh --login admin --reset-password

Shows RIXXX Panel access data from saved config files.
If the plaintext password was not saved, use --reset-password.

Options:
  --reset-password [PASS]  Set a new RIXXX admin password. If PASS is omitted, generate one.
  --login USER            Set/read admin username. Used with --reset-password too.
  --redact                Mask secrets in output.
  --no-redact             Show secrets in output.
  -h, --help              Show this help.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --redact) REDACT=1 ;;
    --no-redact) REDACT=0 ;;
  esac
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-password)
      RESET_PASSWORD=1
      if [[ $# -gt 1 && "${2:-}" != --* ]]; then
        NEW_PASSWORD="$2"
        shift
      fi
      ;;
    --login)
      NEW_LOGIN="${2:-}"
      [[ -n "$NEW_LOGIN" ]] || die "--login requires a value"
      shift
      ;;
    --redact|--no-redact)
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

redact() {
  local value="${1:-}"
  [[ "$REDACT" == "1" ]] || { printf '%s' "$value"; return 0; }
  local len="${#value}"
  if (( len <= 4 )); then
    printf '****'
  elif (( len <= 8 )); then
    printf '%s****' "${value:0:1}"
  else
    printf '%s****%s' "${value:0:2}" "${value: -2}"
  fi
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

config_value() {
  local key="$1" file value
  for file in \
    "$CONFIG_FILE" \
    "$RIXXX_ACCESS_ENV" \
    "/root/unified-proxy-manager/config.env" \
    "/opt/unified-proxy-manager/config.env"; do
    [[ -f "$file" ]] || continue
    value="$(awk -F= -v key="$key" '
      $1 == key {
        value = substr($0, length(key) + 2)
        gsub(/^"/, "", value); gsub(/"$/, "", value)
        print value; exit
      }
    ' "$file" 2>/dev/null || true)"
    [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
  done
}

config_set_file() {
  local file="$1" key="$2" value="$3" tmp dir
  [[ -n "$file" && -n "$key" ]] || return 0
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  touch "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp" 2>/dev/null || true
  awk -v key="$key" -v value="$(env_quote "$value")" '
    BEGIN { done = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      done = 1
      next
    }
    { print }
    END {
      if (!done) print key "=" value
    }
  ' "$file" > "$tmp"
  mv -f "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

json_value() {
  local key="$1" file="${2:-$RIXXX_CONFIG_JSON}"
  [[ -f "$file" ]] || return 0
  node -e '
    const fs = require("fs");
    const key = process.argv[2];
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
    const aliases = {
      panelUrl: ["panelUrl", "panelURL", "url"],
      panelLogin: ["panelLogin", "adminUser", "adminUsername", "username", "login", "user"],
      panelPassword: ["panelPassword", "adminPass", "adminPassword", "password", "pass"],
      panelDir: ["panelDir", "panelPath"],
      domain: ["domain"]
    };
    for (const name of aliases[key] || [key]) {
      const value = cfg[name];
      if (value !== undefined && value !== null && String(value) !== "") {
        process.stdout.write(String(value));
        break;
      }
    }
  ' "$file" "$key" 2>/dev/null || true
}

first_nonempty() {
  local value
  for value in "$@"; do
    [[ -n "$value" && "$value" != "null" ]] && { printf '%s\n' "$value"; return 0; }
  done
}

random_password() {
  local value=""
  if command -v openssl >/dev/null 2>&1; then
    value="$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24 || true)"
  fi
  if [[ -z "$value" && -r /dev/urandom ]]; then
    value="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  fi
  [[ -n "$value" ]] || value="ChangeMe$(date +%s)"
  printf '%s\n' "$value"
}

public_ipv4() {
  local ip
  ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s\n' "$ip"; return 0; }
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$ip"
}

verify_panel_login() {
  command -v node >/dev/null 2>&1 || return 1
  RIXXX_PANEL_URL="${panel_url:-http://127.0.0.1:3000/}" \
    RIXXX_PANEL_LOGIN="$panel_login" \
    RIXXX_PANEL_PASSWORD="$panel_password" \
    node <<'NODE'
const http = require('http');
const { URL } = require('url');

const base = new URL(process.env.RIXXX_PANEL_URL || 'http://127.0.0.1:3000/');
base.pathname = '/api/login';
base.search = '';
const body = JSON.stringify({
  username: process.env.RIXXX_PANEL_LOGIN || 'admin',
  password: process.env.RIXXX_PANEL_PASSWORD || '',
});

const req = http.request({
  hostname: base.hostname,
  port: Number(base.port || 80),
  path: base.pathname,
  method: 'POST',
  timeout: 3000,
  headers: {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  },
}, res => {
  let data = '';
  res.on('data', chunk => { data += chunk; });
  res.on('end', () => {
    if (res.statusCode === 200 && /"ok"\s*:\s*true/.test(data)) process.exit(0);
    console.error(`login check failed: HTTP ${res.statusCode} ${data}`);
    process.exit(1);
  });
});
req.on('timeout', () => { req.destroy(new Error('timeout')); });
req.on('error', err => { console.error(`login check failed: ${err.message}`); process.exit(1); });
req.write(body);
req.end();
NODE
}

panel_dir="$(first_nonempty "$(config_value RIXXX_PANEL_DIR)" "$(json_value panelDir)" "/opt/panel-naive-mieru")"
panel_url="$(first_nonempty "$(config_value RIXXX_PANEL_URL)" "$(config_value NH_PANEL_URL)" "$(json_value panelUrl)" "http://127.0.0.1:3000/")"
panel_login="$(first_nonempty "$NEW_LOGIN" "$(config_value RIXXX_PANEL_LOGIN)" "$(config_value NH_PANEL_LOGIN)" "$(json_value panelLogin)" "admin")"
panel_password="$(first_nonempty "$(config_value RIXXX_PANEL_PASSWORD)" "$(config_value NH_PANEL_PASSWORD)" "$(json_value panelPassword)")"

if [[ "$RESET_PASSWORD" == "1" ]]; then
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "--reset-password must be run as root"
  command -v node >/dev/null 2>&1 || die "node is required"
  [[ -f "$RIXXX_CONFIG_JSON" ]] || die "RIXXX config not found: $RIXXX_CONFIG_JSON"
  [[ -d "$panel_dir" ]] || die "RIXXX panel dir not found: $panel_dir"

  panel_password="${NEW_PASSWORD:-$(random_password)}"
  [[ ${#panel_password} -ge 8 ]] || die "Password must be at least 8 characters"

  if ! PANEL_DIR="$panel_dir" \
    RIXXX_CONFIG_JSON="$RIXXX_CONFIG_JSON" \
    RIXXX_ADMIN_USER="$panel_login" \
    RIXXX_ADMIN_PASS="$panel_password" \
    node <<'NODE'
const fs = require('fs');
const path = require('path');

const panelDir = process.env.PANEL_DIR;
const configFile = process.env.RIXXX_CONFIG_JSON;
const username = process.env.RIXXX_ADMIN_USER || 'admin';
const password = process.env.RIXXX_ADMIN_PASS || '';
if (!password) process.exit(2);

let bcrypt;
const candidates = [
  path.join(panelDir, 'node_modules', 'bcryptjs'),
  path.join(panelDir, 'panel', 'node_modules', 'bcryptjs'),
  path.join('/opt/panel-naive-mieru', 'node_modules', 'bcryptjs'),
  path.join('/opt/panel-naive-mieru', 'panel', 'node_modules', 'bcryptjs'),
  'bcryptjs',
];
for (const candidate of candidates) {
  try {
    bcrypt = require(candidate);
    break;
  } catch {}
}
if (!bcrypt) {
  console.error(`bcryptjs module not found. Panel dir: ${panelDir}`);
  process.exit(3);
}

let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(configFile, 'utf8'));
} catch {}

cfg.adminUser = username;
cfg.adminPassHash = bcrypt.hashSync(password, 12);
fs.writeFileSync(configFile, JSON.stringify(cfg, null, 2), { mode: 0o600 });
NODE
  then
    die "Failed to reset RIXXX panel password. Check panel dir: $panel_dir and node_modules/bcryptjs."
  fi

  config_set_file "$CONFIG_FILE" NH_BACKEND_KIND "rixxx-naive-mieru"
  config_set_file "$CONFIG_FILE" NH_PANEL_URL "$panel_url"
  config_set_file "$CONFIG_FILE" NH_PANEL_LOGIN "$panel_login"
  config_set_file "$CONFIG_FILE" NH_PANEL_PASSWORD "$panel_password"
  config_set_file "$CONFIG_FILE" RIXXX_PANEL_URL "$panel_url"
  config_set_file "$CONFIG_FILE" RIXXX_PANEL_LOGIN "$panel_login"
  config_set_file "$CONFIG_FILE" RIXXX_PANEL_PASSWORD "$panel_password"
  config_set_file "$CONFIG_FILE" RIXXX_PANEL_DIR "$panel_dir"

  config_set_file "$RIXXX_ACCESS_ENV" NH_BACKEND_KIND "rixxx-naive-mieru"
  config_set_file "$RIXXX_ACCESS_ENV" NH_PANEL_URL "$panel_url"
  config_set_file "$RIXXX_ACCESS_ENV" NH_PANEL_LOGIN "$panel_login"
  config_set_file "$RIXXX_ACCESS_ENV" NH_PANEL_PASSWORD "$panel_password"
  config_set_file "$RIXXX_ACCESS_ENV" RIXXX_PANEL_URL "$panel_url"
  config_set_file "$RIXXX_ACCESS_ENV" RIXXX_PANEL_LOGIN "$panel_login"
  config_set_file "$RIXXX_ACCESS_ENV" RIXXX_PANEL_PASSWORD "$panel_password"
  config_set_file "$RIXXX_ACCESS_ENV" RIXXX_PANEL_DIR "$panel_dir"

  if command -v pm2 >/dev/null 2>&1; then
    pm2 restart panel-naive-mieru --update-env >/dev/null 2>&1 || true
    pm2 save >/dev/null 2>&1 || true
  fi
  sleep 2
  printf 'Password reset: saved plaintext access files\n'
  if verify_panel_login; then
    printf 'Login check: OK\n'
  else
    printf 'Login check: FAILED. Check: pm2 logs panel-naive-mieru\n' >&2
  fi
fi

server_ip="$(public_ipv4)"

printf 'RIXXX Panel access\n'
printf '==================\n\n'
printf 'URL:        %s\n' "${panel_url:-http://127.0.0.1:3000/}"
printf 'Login:      %s\n' "${panel_login:-admin}"
if [[ -n "$panel_password" ]]; then
  printf 'Password:   %s\n' "$(redact "$panel_password")"
else
  printf 'Password:   not saved in plaintext\n'
  printf 'Fix:        sudo bash rixxx-panel-access.sh --reset-password\n'
fi
printf 'Config:     %s\n' "$RIXXX_CONFIG_JSON"
printf 'Panel dir:  %s\n' "$panel_dir"
printf '\n'
printf 'SSH tunnel: ssh -L 3000:127.0.0.1:3000 root@%s\n' "${server_ip:-SERVER_IP}"
printf 'Browser:    http://127.0.0.1:3000/\n'
