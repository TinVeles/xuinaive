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

nginx_web_sub_path() {
  local file="/etc/nginx/snippets/includes.conf"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*location[[:space:]]+~[[:space:]]+\^\/([^\/ {]+).*/\1/p' "$file" 2>/dev/null | head -n1
}

nginx_sub2sing_path() {
  local file="/etc/nginx/snippets/includes.conf"
  [[ -f "$file" ]] || return 0
  awk '/proxy_pass http:\/\/127\.0\.0\.1:8080\// {print prev} {prev=$0}' "$file" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*location[[:space:]]+\/([^\/ {]+)\/[[:space:]]*\{.*/\1/p' \
    | head -n1
}

public_ipv4() {
  curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true
}

server_ip="$(public_ipv4)"
[[ -n "$server_ip" ]] || server_ip="SERVER_IP"

XUI_DOMAIN="$(config_value XUI_DOMAIN)"
NH_DOMAIN="$(config_value NH_PROXY_DOMAIN)"
PANEL_PORT="$(config_value NH_PANEL_PORT)"
[[ -n "$PANEL_PORT" ]] || PANEL_PORT="8081"

xui_user="$(xui_setting username)"
xui_pass="$(xui_setting password)"
xui_path="$(xui_setting webBasePath)"
xui_path="${xui_path#/}"; xui_path="${xui_path%/}"
if [[ -n "$XUI_DOMAIN" ]]; then
  [[ -n "$xui_path" ]] && xui_url="https://${XUI_DOMAIN}/${xui_path}/" || xui_url="https://${XUI_DOMAIN}/"
else
  xui_url="check x-ui settings"
fi

profile_prefix="$(config_value PROFILE_PREFIX)"; [[ -n "$profile_prefix" ]] || profile_prefix="auto"
profile_count="$(config_value PROFILE_COUNT)"; [[ -n "$profile_count" ]] || profile_count="15"
profile_last="$(printf '%02d' "$profile_count" 2>/dev/null || printf '%s' "$profile_count")"

xui_web_path="$(nginx_web_sub_path)"
xui_sub2sing_path="$(nginx_sub2sing_path)"
xui_sub_uri="$(xui_setting subURI)"
[[ -n "$xui_sub_uri" && "$xui_sub_uri" != */ ]] && xui_sub_uri="${xui_sub_uri}/"

if [[ -n "$XUI_DOMAIN" && -n "$xui_web_path" ]]; then
  xui_web_sub_url="https://${XUI_DOMAIN}/${xui_web_path}?name=${profile_prefix}-01 ... ${profile_prefix}-${profile_last}"
else
  xui_web_sub_url="check /etc/nginx/snippets/includes.conf"
fi
if [[ -n "$xui_sub_uri" ]]; then
  xui_raw_sub_url="${xui_sub_uri}${profile_prefix}-01 ... ${profile_prefix}-${profile_last}"
else
  xui_raw_sub_url="check x-ui setting subURI"
fi
if [[ -n "$XUI_DOMAIN" && -n "$xui_sub2sing_path" ]]; then
  xui_sub2sing_url="https://${XUI_DOMAIN}/${xui_sub2sing_path}/"
else
  xui_sub2sing_url="check /etc/nginx/snippets/includes.conf"
fi

nh_panel_url="$(config_value NH_PANEL_URL)"
nh_panel_url="${nh_panel_url/SERVER_IP/$server_ip}"
[[ -n "$nh_panel_url" ]] || nh_panel_url="http://${server_ip}:${PANEL_PORT}"
nh_panel_login="$(config_value NH_PANEL_LOGIN)"; [[ -n "$nh_panel_login" ]] || nh_panel_login="admin"
nh_panel_password="$(config_value NH_PANEL_PASSWORD)"; [[ -n "$nh_panel_password" ]] || nh_panel_password="check config.env or /opt/panel-naive-hy2/panel/data/initial-admin.txt"

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
Panel access
============

3x-ui / x-ui panel
  URL:      ${xui_url}
  Login:    ${xui_user:-check with: x-ui settings}
  Password: ${xui_pass:-check with: x-ui settings}

3x-ui subscriptions
  Web page: ${xui_web_sub_url}
  Raw sub:  ${xui_raw_sub_url}
  sub2sing: ${xui_sub2sing_url}

N+H Panel
  URL:      ${nh_panel_url}
  Login:    ${nh_panel_login}
  Password: ${nh_panel_password}

NaiveProxy
  Login:    ${naive_login:-check config.env}
  Password: ${naive_password:-check config.env}
  Link:     ${naive_link:-check config.env}

Hysteria2
  User:     ${hy2_user:-check config.env}
  Password: ${hy2_password:-check config.env}
  Link:     ${hy2_link:-check config.env}
EOF
chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

echo ""
echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║   ✅  Установка завершена!                                  ║${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🌐  3x-ui / x-ui panel                                    ║${RESET}"
echo -e "${PURPLE}${BOLD}║   URL:      ${xui_url}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${xui_user:-check with: x-ui settings}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${xui_pass:-check with: x-ui settings}${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   📡  3x-ui subscriptions                                   ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Web Sub Page:${RESET}"
echo -e "${CYAN}   ${xui_web_sub_url}${RESET}"
echo -e "${PURPLE}${BOLD}║   Raw Sub:${RESET}"
echo -e "${CYAN}   ${xui_raw_sub_url}${RESET}"
echo -e "${PURPLE}${BOLD}║   sub2sing-box:${RESET}"
echo -e "${CYAN}   ${xui_sub2sing_url}${RESET}"
echo -e "${PURPLE}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${PURPLE}${BOLD}║   🧩  N+H Panel                                             ║${RESET}"
echo -e "${PURPLE}${BOLD}║   URL:      ${nh_panel_url}${RESET}"
echo -e "${PURPLE}${BOLD}║   Login:    ${nh_panel_login}${RESET}"
echo -e "${PURPLE}${BOLD}║   Password: ${nh_panel_password}${RESET}"

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
echo -e "${PURPLE}${BOLD}║   📌  Полезные команды                                      ║${RESET}"
echo -e "${PURPLE}${BOLD}║   x-ui                           — меню 3x-ui               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status x-ui          — статус x-ui              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status caddy-nh      — NaiveProxy               ║${RESET}"
echo -e "${PURPLE}${BOLD}║   systemctl status hysteria-server — Hysteria2              ║${RESET}"
echo -e "${PURPLE}${BOLD}║   Saved file: ${SUMMARY_FILE}${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
