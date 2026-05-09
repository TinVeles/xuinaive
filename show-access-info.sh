#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"
NH_CONFIG_JSON="${NH_CONFIG_JSON:-/opt/panel-naive-hy2/panel/data/config.json}"
NH_GENERATED_PROFILES="${NH_GENERATED_PROFILES:-/opt/panel-naive-hy2/generated-profiles.txt}"

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

profile_link() {
  local section="$1" prefix="$2"
  [[ -f "$NH_GENERATED_PROFILES" ]] || return 0
  awk -v section="$section" -v prefix="$prefix" '
    $0 == section ":" { in_section=1; next }
    in_section && $0 == "" { exit }
    in_section && index($0, prefix) == 1 { print; exit }
  ' "$NH_GENERATED_PROFILES" 2>/dev/null || true
}

XUI_DOMAIN="$(first_nonempty "$(config_value XUI_DOMAIN)" "$(xui_setting webDomain)" "$(xui_setting subDomain)" "$(xui_domain_from_cert)")"
NH_DOMAIN="$(first_nonempty "$(config_value NH_PROXY_DOMAIN)" "$(json_value domain)")"
nh_panel_port="$(first_nonempty "$(config_value NH_PANEL_PORT)" "8081")"
nh_panel_url="$(first_nonempty "$(config_value NH_PANEL_URL)" "$(json_value panelUrl)")"
nh_panel_login="$(first_nonempty "$(config_value NH_PANEL_LOGIN)" "$(json_value panelLogin)")"
nh_panel_password="$(first_nonempty "$(config_value NH_PANEL_PASSWORD)" "$(json_value panelPassword)")"
if [[ -z "$nh_panel_url" && -n "$nh_panel_port" ]]; then
  server_ip="$(public_ipv4)"
  [[ -n "$server_ip" ]] && nh_panel_url="http://${server_ip}:${nh_panel_port}"
fi

xui_user="$(first_nonempty "$(xui_setting username)" "$(xui_user_from_db)")"
xui_pass="$(first_nonempty "$(xui_setting password)" "$(xui_pass_from_db)")"
xui_path="$(xui_setting webBasePath)"
xui_path="${xui_path#/}"; xui_path="${xui_path%/}"
if [[ -n "$(xui_setting webPort)" && -n "$XUI_DOMAIN" ]]; then
  xui_port="$(xui_setting webPort)"
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}:${xui_port}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}:${xui_port}/"
elif [[ -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}/"
else
  xui_url="check x-ui settings"
fi

naive_login="$(first_nonempty "$(config_value NH_NAIVE_LOGIN)" "$(json_value naiveLogin)")"
naive_password="$(first_nonempty "$(config_value NH_NAIVE_PASSWORD)" "$(json_value naivePassword)")"
naive_link="$(first_nonempty "$(config_value NH_NAIVE_LINK)" "$(profile_link NaiveProxy 'naive+https://')")"
if [[ -z "$naive_link" && -n "$NH_DOMAIN" && -n "$naive_login" && -n "$naive_password" ]]; then
  naive_link="naive+https://${naive_login}:${naive_password}@${NH_DOMAIN}:443"
fi
hy2_user="$(first_nonempty "$(config_value NH_HY2_USER)" "$(json_value hy2User)")"
hy2_password="$(first_nonempty "$(config_value NH_HY2_PASSWORD)" "$(json_value hy2Password)")"
hy2_link="$(first_nonempty "$(config_value NH_HY2_LINK)" "$(profile_link Hysteria2 'hysteria2://')")"
if [[ -z "$hy2_link" && -n "$NH_DOMAIN" && -n "$hy2_password" ]]; then
  hy2_link="hysteria2://${hy2_user:-default}:${hy2_password}@${NH_DOMAIN}:443?sni=${NH_DOMAIN}&insecure=0#${hy2_user:-default}"
fi

reset_terminal_style
cat > "$SUMMARY_FILE" <<EOF
Install access
==============

3x-ui / x-ui panel
  URL:      ${xui_url}
  Login:    ${xui_user:-check with: x-ui settings}
  Password: ${xui_pass:-check with: x-ui settings}

NaiveProxy
  Domain:   ${NH_DOMAIN:-check config.env}
  Login:    ${naive_login:-check config.env}
  Password: ${naive_password:-check config.env}
  Link:     ${naive_link:-check config.env}

Naive + Hysteria2 panel
  URL:      ${nh_panel_url:-check config.env}
  Login:    ${nh_panel_login:-check config.env}
  Password: ${nh_panel_password:-check config.env}

Hysteria2
  Domain:   ${NH_DOMAIN:-check config.env}
  User:     ${hy2_user:-check config.env}
  Password: ${hy2_password:-check config.env}
  Link:     ${hy2_link:-check config.env}
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
echo -e "${PURPLE}${BOLD}║   🔒  NaiveProxy                                            ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Domain:   ${NH_DOMAIN:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${naive_login:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${naive_password:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Link:${RESET}"
echo -e "${CYAN}   ${naive_link:-check config.env}${RESET}"

echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🖥  Naive + Hysteria2 Panel                               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   URL:${RESET}"
echo -e "${CYAN}   ${nh_panel_url:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${nh_panel_login:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${nh_panel_password:-check config.env}${RESET}"

echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   ⚡  Hysteria2                                             ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Domain:   ${NH_DOMAIN:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   User:     ${hy2_user:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${hy2_password:-check config.env}${RESET}"
echo -e "${PURPLE}${BOLD}║   Link:${RESET}"
echo -e "${CYAN}   ${hy2_link:-check config.env}${RESET}"

echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   📌  Команды                                               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   x-ui                           — меню x-ui                ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status x-ui          — статус x-ui              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status caddy-nh      — статус NaiveProxy        ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status hysteria-server — статус Hysteria2       ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
