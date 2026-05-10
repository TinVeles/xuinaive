#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"
NH_CONFIG_JSON="${NH_CONFIG_JSON:-/opt/panel-naive-hy2/panel/data/config.json}"
NH_PANEL_USERS_JSON="${NH_PANEL_USERS_JSON:-/opt/panel-naive-hy2/panel/data/users.json}"
NH_PANEL_INITIAL_ADMIN="${NH_PANEL_INITIAL_ADMIN:-/opt/panel-naive-hy2/panel/data/initial-admin.txt}"
NH_CADDYFILE="${NH_CADDYFILE:-/etc/caddy-nh/Caddyfile}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  PURPLE=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  RESET=$'\033[0m'
else
  BOLD=""
  PURPLE=""
  CYAN=""
  RESET=""
fi

reset_terminal_style() {
  [[ -t 1 ]] && printf '\033[0m\033[24m\033[25m' || true
}
trap reset_terminal_style EXIT
reset_terminal_style

config_value() {
  local key="$1"
  local file value
  for file in \
    "$CONFIG_FILE" \
    "/etc/x-ui/access-info.env" \
    "/root/unified-proxy-manager/config.env" \
    "/opt/unified-proxy-manager/config.env" \
    "/etc/nh-panel/config.env"; do
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
  return 0
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

config_set_file() {
  local file="$1" key="$2" value="$3" tmp dir
  [[ -n "$file" && -n "$key" ]] || return 0
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 0
  touch "$file" 2>/dev/null || return 0
  tmp="${file}.tmp.$$"
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
  ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 0; }
  chmod 600 "$file" 2>/dev/null || true
}

random_password() {
  local value
  if command -v openssl >/dev/null 2>&1; then
    value="$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24 || true)"
  fi
  if [[ -z "${value:-}" && -r /dev/urandom ]]; then
    value="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  fi
  printf '%s\n' "$value"
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

json_value() {
  local expr="$1" file="${2:-$NH_CONFIG_JSON}"
  [[ -f "$file" ]] || return 0
  node -e '
    const fs = require("fs");
    const expr = process.argv[2];
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    function first(arr) {
      return Array.isArray(arr) && arr.length ? arr[0] : {};
    }
    const map = {
      domain: cfg.domain,
      panelUrl: cfg.panelUrl || cfg.panelURL,
      panelLogin: cfg.panelLogin || cfg.login,
      panelPassword: cfg.panelPassword || cfg.password,
      naiveLogin: first(cfg.naiveUsers).username,
      naivePassword: first(cfg.naiveUsers).password,
      hy2User: first(cfg.hy2Users).username || "default",
      hy2Password: first(cfg.hy2Users).password
    };
    const value = map[expr];
    if (value !== undefined && value !== null) process.stdout.write(String(value));
  ' "$file" "$expr" 2>/dev/null || true
}

public_ipv4() {
  local ip
  ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$ip"
}

first_nonempty() {
  local value
  for value in "$@"; do
    [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }
  done
  return 0
}

sql_quote() {
  local escaped
  escaped="${1//\'/\'\'}"
  printf "'%s'" "$escaped"
}

xui_setting() {
  local key="$1"
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 -noheader -batch /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" 2>/dev/null || true
  fi
}

xui_user_from_db() {
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 -noheader -batch /etc/x-ui/x-ui.db "SELECT username FROM users LIMIT 1;" 2>/dev/null || true
  fi
}

xui_pass_from_db() {
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 -noheader -batch /etc/x-ui/x-ui.db "SELECT password FROM users LIMIT 1;" 2>/dev/null || true
  fi
}

xui_domain_from_cert() {
  local cert cert_dir
  cert="$(xui_setting webCertFile)"
  if [[ -n "$cert" && "$cert" == */fullchain.pem ]]; then
    cert_dir="$(dirname "$cert")"
    basename "$cert_dir"
    return 0
  fi
  find /root/cert -mindepth 2 -maxdepth 2 -name fullchain.pem -print 2>/dev/null \
    | awk -F/ 'NF >= 5 { print $(NF-1); exit }' || true
}

nh_panel_login_from_users() {
  [[ -f "$NH_PANEL_USERS_JSON" ]] || return 0
  node -e '
    const fs = require("fs");
    const users = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const first = Object.keys(users)[0];
    if (first) process.stdout.write(first);
  ' "$NH_PANEL_USERS_JSON" 2>/dev/null || true
}

nh_panel_initial_login() {
  [[ -f "$NH_PANEL_INITIAL_ADMIN" ]] || return 0
  awk -F: 'NF >= 2 { print $1; exit }' "$NH_PANEL_INITIAL_ADMIN" 2>/dev/null || true
}

nh_panel_initial_password() {
  [[ -f "$NH_PANEL_INITIAL_ADMIN" ]] || return 0
  awk -F: 'NF >= 2 { print $2; exit }' "$NH_PANEL_INITIAL_ADMIN" 2>/dev/null || true
}

nh_naive_login_from_caddy() {
  [[ -f "$NH_CADDYFILE" ]] || return 0
  awk '/^[[:space:]]*basic_auth[[:space:]]/ { print $2; exit }' "$NH_CADDYFILE" 2>/dev/null || true
}

nh_naive_password_from_caddy() {
  [[ -f "$NH_CADDYFILE" ]] || return 0
  awk '/^[[:space:]]*basic_auth[[:space:]]/ { print $3; exit }' "$NH_CADDYFILE" 2>/dev/null || true
}

sync_nh_naive_config_from_caddy() {
  is_root || return 0
  [[ -f "$NH_CADDYFILE" && -f "$NH_CONFIG_JSON" ]] || return 0
  CADDYFILE="$NH_CADDYFILE" CONFIG_JSON="$NH_CONFIG_JSON" node <<'NODE' >/dev/null 2>&1 || true
const fs = require('fs');
const caddyfile = process.env.CADDYFILE;
const configJson = process.env.CONFIG_JSON;

const text = fs.readFileSync(caddyfile, 'utf8');
const users = [];
for (const line of text.split(/\r?\n/)) {
  const match = line.match(/^\s*basic_auth\s+(\S+)\s+(\S+)/);
  if (match) users.push({ username: match[1], password: match[2] });
}
if (!users.length) process.exit(0);

let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(configJson, 'utf8'));
} catch {
  cfg = {};
}

const existing = new Map(
  Array.isArray(cfg.naiveUsers)
    ? cfg.naiveUsers.map(u => [String(u.username || ''), u])
    : []
);
const now = new Date().toISOString();
cfg.stack = cfg.stack || {};
cfg.stack.naive = true;
cfg.installed = cfg.installed !== false;
cfg.naiveUsers = users.map(u => ({
  ...(existing.get(u.username) || {}),
  username: u.username,
  password: u.password,
  createdAt: (existing.get(u.username) || {}).createdAt || now
}));

fs.writeFileSync(configJson, JSON.stringify(cfg, null, 2), { mode: 0o600 });
NODE
}

persist_xui_access() {
  local file="/etc/x-ui/access-info.env"
  config_set_file "$file" XUI_DOMAIN "${XUI_DOMAIN:-}"
  config_set_file "$file" XUI_PANEL_URL "${xui_url:-}"
  config_set_file "$file" XUI_PANEL_LOGIN "${xui_user:-}"
  config_set_file "$file" XUI_PANEL_PASSWORD "${xui_pass:-}"
  config_set_file "$file" XUI_PANEL_PORT "${xui_port:-}"
  config_set_file "$file" XUI_PANEL_PATH "${xui_path:+/${xui_path}/}"

  config_set_file "$CONFIG_FILE" XUI_PANEL_URL "${xui_url:-}"
  config_set_file "$CONFIG_FILE" XUI_PANEL_LOGIN "${xui_user:-}"
  config_set_file "$CONFIG_FILE" XUI_PANEL_PASSWORD "${xui_pass:-}"
}

reset_xui_password_if_missing() {
  local new_pass
  [[ -z "${xui_pass:-}" ]] || return 0
  is_root || return 0
  [[ -x /usr/local/x-ui/x-ui ]] || return 0

  xui_user="${xui_user:-admin}"
  new_pass="$(random_password)"
  [[ -n "$new_pass" ]] || return 0

  local args=(setting -username "$xui_user" -password "$new_pass")
  [[ -n "${xui_port:-}" ]] && args+=(-port "$xui_port")
  [[ -n "${xui_path:-}" ]] && args+=(-webBasePath "$xui_path")
  if /usr/local/x-ui/x-ui "${args[@]}" >/dev/null 2>&1; then
    xui_pass="$new_pass"
    persist_xui_access
    systemctl restart x-ui >/dev/null 2>&1 || true
  fi
}

reset_nh_panel_password_if_missing() {
  local new_pass panel_dir
  [[ -z "${nh_panel_password:-}" ]] || return 0
  is_root || return 0
  panel_dir="$(dirname "$(dirname "$NH_CONFIG_JSON")")"
  [[ -d "$panel_dir" ]] || panel_dir="/opt/panel-naive-hy2/panel"
  [[ -d "$panel_dir" ]] || return 0
  [[ -d "$panel_dir/node_modules/bcryptjs" ]] || return 0

  nh_panel_login="${nh_panel_login:-admin}"
  new_pass="$(random_password)"
  [[ -n "$new_pass" ]] || return 0

  if (
     cd "$panel_dir"
     PANEL_LOGIN="$nh_panel_login" \
       PANEL_PASSWORD="$new_pass" \
       PANEL_URL="${nh_panel_url:-}" \
       CONFIG_JSON="$NH_CONFIG_JSON" \
       USERS_JSON="$NH_PANEL_USERS_JSON" \
       INITIAL_ADMIN="$NH_PANEL_INITIAL_ADMIN" \
       node <<'NODE' >/dev/null 2>&1
const fs = require('fs');
const path = require('path');
const bcrypt = require('bcryptjs');

const login = process.env.PANEL_LOGIN || 'admin';
const password = process.env.PANEL_PASSWORD || '';
const configJson = process.env.CONFIG_JSON;
const usersJson = process.env.USERS_JSON;
const initialAdmin = process.env.INITIAL_ADMIN;
if (!password || !configJson || !usersJson) process.exit(1);

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

fs.mkdirSync(path.dirname(usersJson), { recursive: true });
const loadedUsers = readJson(usersJson, {});
const users = loadedUsers && !Array.isArray(loadedUsers) && typeof loadedUsers === 'object' ? loadedUsers : {};
const current = users[login] && typeof users[login] === 'object' ? users[login] : {};
users[login] = {
  ...current,
  password: bcrypt.hashSync(password, 10),
  role: current.role || 'admin'
};
fs.writeFileSync(usersJson, JSON.stringify(users, null, 2), { mode: 0o600 });

fs.mkdirSync(path.dirname(configJson), { recursive: true });
const cfg = readJson(configJson, {});
cfg.panelLogin = login;
cfg.panelPassword = password;
if (process.env.PANEL_URL) cfg.panelUrl = process.env.PANEL_URL;
fs.writeFileSync(configJson, JSON.stringify(cfg, null, 2), { mode: 0o600 });

if (initialAdmin) {
  fs.mkdirSync(path.dirname(initialAdmin), { recursive: true });
  fs.writeFileSync(initialAdmin, `${login}:${password}\n`, { mode: 0o600 });
}
NODE
  )
  then
    nh_panel_password="$new_pass"
    config_set_file "$CONFIG_FILE" NH_PANEL_URL "${nh_panel_url:-}"
    config_set_file "$CONFIG_FILE" NH_PANEL_LOGIN "$nh_panel_login"
    config_set_file "$CONFIG_FILE" NH_PANEL_PASSWORD "$nh_panel_password"
    systemctl restart panel-naive-hy2 >/dev/null 2>&1 || true
  fi
}

persist_nh_naive_access() {
  local domain login password link
  domain="$(first_nonempty "$(config_value NH_PROXY_DOMAIN)" "$(config_value NAIVE_DOMAIN)" "$(json_value domain)")"
  login="$(first_nonempty "$(config_value NH_NAIVE_LOGIN)" "$(json_value naiveLogin)" "$(nh_naive_login_from_caddy)")"
  password="$(first_nonempty "$(config_value NH_NAIVE_PASSWORD)" "$(json_value naivePassword)" "$(nh_naive_password_from_caddy)")"
  [[ "$domain" == "null" ]] && domain=""
  [[ "$login" == "null" ]] && login=""
  [[ "$password" == "null" ]] && password=""
  [[ -n "$domain" && -n "$login" && -n "$password" ]] || return 0

  link="naive+https://${login}:${password}@${domain}:443"
  config_set_file "$CONFIG_FILE" NH_PROXY_DOMAIN "$domain"
  config_set_file "$CONFIG_FILE" NAIVE_DOMAIN "$domain"
  config_set_file "$CONFIG_FILE" NH_NAIVE_LOGIN "$login"
  config_set_file "$CONFIG_FILE" NH_NAIVE_PASSWORD "$password"
  config_set_file "$CONFIG_FILE" NH_NAIVE_LINK "$link"
}

ensure_nh_panel_nginx_proxy() {
  local port="${nh_panel_port:-}" conf="/etc/nginx/sites-available/panel-naive-hy2"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  is_root || return 0
  command -v nginx >/dev/null 2>&1 || return 0
  [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]] || return 0
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi

  if ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
    return 0
  fi

  cat > "$conf" <<EOF
server {
    listen ${port};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }
}
EOF
  ln -sf "$conf" /etc/nginx/sites-enabled/panel-naive-hy2
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  fi
}

ensure_nh_naive_sni_route() {
  local domain backend patch_script stream_conf="/etc/nginx/stream-enabled/stream.conf"
  domain="$(first_nonempty "$(config_value NH_PROXY_DOMAIN)" "$(config_value NAIVE_DOMAIN)" "$(json_value domain)")"
  backend="$(first_nonempty "$(config_value NH_BACKEND_LISTEN)" "127.0.0.1:9445")"
  patch_script="$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh"

  [[ -n "$domain" && "$domain" != "null" ]] || return 0
  [[ -n "$backend" && "$backend" != "null" ]] || return 0
  is_root || return 0
  [[ -f "$stream_conf" && -f "$patch_script" ]] || return 0

  if awk -v d="$domain" '$1 == d && $2 == "nh_naive;" { found = 1 } END { exit found ? 0 : 1 }' "$stream_conf" 2>/dev/null \
     && awk -v b="$backend;" '$1 == "server" && $2 == b { found = 1 } END { exit found ? 0 : 1 }' "$stream_conf" 2>/dev/null; then
    return 0
  fi

  bash "$patch_script" --domain "$domain" --backend "$backend" --name nh_naive >/dev/null 2>&1 || true
}

XUI_DOMAIN="$(first_nonempty "$(config_value XUI_DOMAIN)" "$(xui_setting webDomain)" "$(xui_setting subDomain)" "$(xui_domain_from_cert)")"
nh_panel_port="$(first_nonempty "$(config_value NH_PANEL_PORT)" "8081")"
nh_panel_url="$(first_nonempty "$(config_value NH_PANEL_URL)" "$(json_value panelUrl)")"
nh_panel_login="$(first_nonempty "$(config_value NH_PANEL_LOGIN)" "$(json_value panelLogin)" "$(nh_panel_initial_login)" "$(nh_panel_login_from_users)")"
nh_panel_password="$(first_nonempty "$(config_value NH_PANEL_PASSWORD)" "$(json_value panelPassword)" "$(nh_panel_initial_password)")"
[[ "$nh_panel_url" == "null" ]] && nh_panel_url=""
[[ "$nh_panel_login" == "null" ]] && nh_panel_login=""
[[ "$nh_panel_password" == "null" ]] && nh_panel_password=""
[[ "$nh_panel_url" == *SERVER_IP* ]] && nh_panel_url=""
if [[ -z "$nh_panel_url" && -n "$nh_panel_port" ]]; then
  server_ip="$(public_ipv4)"
  [[ -n "$server_ip" ]] && nh_panel_url="http://${server_ip}:${nh_panel_port}"
fi

xui_user="$(first_nonempty "$(config_value XUI_PANEL_LOGIN)" "$(config_value XUI_LOGIN)" "$(xui_setting username)" "$(xui_user_from_db)")"
xui_pass="$(first_nonempty "$(config_value XUI_PANEL_PASSWORD)" "$(config_value XUI_PASSWORD)" "$(xui_setting password)" "$(xui_pass_from_db)")"
[[ "$xui_user" == "null" ]] && xui_user=""
[[ "$xui_pass" == "null" ]] && xui_pass=""
if [[ "$xui_pass" == \$2a\$* || "$xui_pass" == \$2b\$* || "$xui_pass" == \$2y\$* ]]; then
  xui_pass=""
fi
xui_port="$(xui_setting webPort)"
xui_path="$(xui_setting webBasePath)"
xui_path="${xui_path#/}"; xui_path="${xui_path%/}"
xui_url="$(first_nonempty "$(config_value XUI_PANEL_URL)" "$(config_value XUI_URL)")"
if [[ -n "$xui_url" ]]; then
  :
elif [[ -n "$xui_port" && -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}:${xui_port}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}:${xui_port}/"
elif [[ -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}/"
else
  xui_url="check x-ui settings"
fi

reset_xui_password_if_missing
reset_nh_panel_password_if_missing
sync_nh_naive_config_from_caddy
persist_nh_naive_access
ensure_nh_panel_nginx_proxy
ensure_nh_naive_sni_route

reset_terminal_style
cat > "$SUMMARY_FILE" <<EOF
Install access
==============

3x-ui / x-ui panel
  URL:      ${xui_url}
  Login:    ${xui_user:-check with: x-ui settings}
  Password: ${xui_pass:-check with: x-ui settings}

Naive + Hysteria2 panel
  URL:      ${nh_panel_url:-check config.env}
  Login:    ${nh_panel_login:-check config.env}
  Password: ${nh_panel_password:-check config.env}
EOF
chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Установка завершена!                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  x-ui                                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}║   URL:${RESET}"
echo -e "${CYAN}   ${xui_url}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${xui_user:-check with: x-ui settings}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${xui_pass:-check with: x-ui settings}${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🖥  Naive + Hysteria2 Panel                               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   URL:${RESET}"
echo -e "${CYAN}   ${nh_panel_url:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${nh_panel_login:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${nh_panel_password:-check config.env}${RESET}"

echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   📌  Команды                                               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   x-ui                           — меню x-ui                ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status x-ui          — статус x-ui              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status panel-naive-hy2 — статус N+H панели      ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
