#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"
NH_CONFIG_JSON="${NH_CONFIG_JSON:-/opt/panel-naive-hy2/panel/data/config.json}"
NH_PANEL_USERS_JSON="${NH_PANEL_USERS_JSON:-/opt/panel-naive-hy2/panel/data/users.json}"
NH_PANEL_INITIAL_ADMIN="${NH_PANEL_INITIAL_ADMIN:-/opt/panel-naive-hy2/panel/data/initial-admin.txt}"

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

XUI_DOMAIN="$(first_nonempty "$(config_value XUI_DOMAIN)" "$(xui_setting webDomain)" "$(xui_setting subDomain)" "$(xui_domain_from_cert)")"
nh_panel_port="$(first_nonempty "$(config_value NH_PANEL_PORT)" "8081")"
nh_panel_url="$(first_nonempty "$(config_value NH_PANEL_URL)" "$(json_value panelUrl)")"
nh_panel_login="$(first_nonempty "$(config_value NH_PANEL_LOGIN)" "$(json_value panelLogin)" "$(nh_panel_initial_login)" "$(nh_panel_login_from_users)")"
nh_panel_password="$(first_nonempty "$(config_value NH_PANEL_PASSWORD)" "$(json_value panelPassword)" "$(nh_panel_initial_password)")"
[[ "$nh_panel_url" == *SERVER_IP* ]] && nh_panel_url=""
if [[ -z "$nh_panel_url" && -n "$nh_panel_port" ]]; then
  server_ip="$(public_ipv4)"
  [[ -n "$server_ip" ]] && nh_panel_url="http://${server_ip}:${nh_panel_port}"
fi

xui_user="$(first_nonempty "$(config_value XUI_PANEL_LOGIN)" "$(config_value XUI_LOGIN)" "$(xui_setting username)" "$(xui_user_from_db)")"
xui_pass="$(first_nonempty "$(config_value XUI_PANEL_PASSWORD)" "$(config_value XUI_PASSWORD)" "$(xui_setting password)" "$(xui_pass_from_db)")"
if [[ "$xui_pass" == \$2a\$* || "$xui_pass" == \$2b\$* || "$xui_pass" == \$2y\$* ]]; then
  xui_pass=""
fi
xui_path="$(xui_setting webBasePath)"
xui_path="${xui_path#/}"; xui_path="${xui_path%/}"
xui_url="$(first_nonempty "$(config_value XUI_PANEL_URL)" "$(config_value XUI_URL)")"
if [[ -n "$xui_url" ]]; then
  :
elif [[ -n "$(xui_setting webPort)" && -n "$XUI_DOMAIN" ]]; then
  xui_port="$(xui_setting webPort)"
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}:${xui_port}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}:${xui_port}/"
elif [[ -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}/"
else
  xui_url="check x-ui settings"
fi

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
