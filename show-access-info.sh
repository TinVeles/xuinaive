#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"

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
  [[ -f "$CONFIG_FILE" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^"/, "", value); gsub(/"$/, "", value)
      print value; exit
    }
  ' "$CONFIG_FILE" 2>/dev/null || true
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

XUI_DOMAIN="$(config_value XUI_DOMAIN)"
NH_DOMAIN="$(config_value NH_PROXY_DOMAIN)"

xui_user="$(xui_setting username)"
xui_pass="$(xui_setting password)"
xui_path="$(xui_setting webBasePath)"
xui_path="${xui_path#/}"; xui_path="${xui_path%/}"
if [[ -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}/"
else
  xui_url="check x-ui settings"
fi

naive_login="$(config_value NH_NAIVE_LOGIN)"
naive_password="$(config_value NH_NAIVE_PASSWORD)"
naive_link="$(config_value NH_NAIVE_LINK)"
if [[ -z "$naive_link" && -n "$NH_DOMAIN" && -n "$naive_login" && -n "$naive_password" ]]; then
  naive_link="naive+https://${naive_login}:${naive_password}@${NH_DOMAIN}:443"
fi
hy2_user="$(config_value NH_HY2_USER)"
hy2_password="$(config_value NH_HY2_PASSWORD)"
hy2_link="$(config_value NH_HY2_LINK)"
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
