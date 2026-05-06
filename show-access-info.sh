#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; NC=""
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

nh_panel_url="$(config_value NH_PANEL_URL)"
nh_panel_url="${nh_panel_url/SERVER_IP/$server_ip}"
[[ -n "$nh_panel_url" ]] || nh_panel_url="http://${server_ip}:${PANEL_PORT}"
nh_panel_login="$(config_value NH_PANEL_LOGIN)"; [[ -n "$nh_panel_login" ]] || nh_panel_login="admin"
nh_panel_password="$(config_value NH_PANEL_PASSWORD)"; [[ -n "$nh_panel_password" ]] || nh_panel_password="check config.env or /opt/panel-naive-hy2/panel/data/initial-admin.txt"

reset_terminal_style
cat > "$SUMMARY_FILE" <<EOF
Panel access
============

3x-ui / x-ui panel
  URL:      ${xui_url}
  Login:    ${xui_user:-check with: x-ui settings}
  Password: ${xui_pass:-check with: x-ui settings}

N+H Panel
  URL:      ${nh_panel_url}
  Login:    ${nh_panel_login}
  Password: ${nh_panel_password}
EOF
chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

cat <<EOF

${BOLD}${GREEN}============================================================${NC}
${BOLD}${GREEN}                 PANEL ACCESS                              ${NC}
${BOLD}${GREEN}============================================================${NC}

${BOLD}${CYAN}3x-ui / x-ui panel${NC}
  ${BOLD}URL:${NC}      ${xui_url}
  ${BOLD}Login:${NC}    ${xui_user:-check with: x-ui settings}
  ${BOLD}Password:${NC} ${xui_pass:-check with: x-ui settings}

${BOLD}${CYAN}N+H Panel${NC}
  ${BOLD}URL:${NC}      ${nh_panel_url}
  ${BOLD}Login:${NC}    ${nh_panel_login}
  ${BOLD}Password:${NC} ${nh_panel_password}

${BOLD}${GREEN}Saved copy-friendly file:${NC}
  ${SUMMARY_FILE}

EOF
