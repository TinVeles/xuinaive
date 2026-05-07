#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SUMMARY_FILE="$SCRIPT_DIR/access-info.txt"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  BOLD=""; BLUE=""; NC=""
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

naive_login="$(config_value NH_NAIVE_LOGIN)"
naive_password="$(config_value NH_NAIVE_PASSWORD)"
hy2_user="$(config_value NH_HY2_USER)"
hy2_password="$(config_value NH_HY2_PASSWORD)"

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

NaiveProxy
  Login:    ${naive_login:-check config.env}
  Password: ${naive_password:-check config.env}

Hysteria2
  User:     ${hy2_user:-check config.env}
  Password: ${hy2_password:-check config.env}
EOF
chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

cat <<EOF

${BOLD}${BLUE}============================================================${NC}
${BOLD}${BLUE}                 PANEL ACCESS                              ${NC}
${BOLD}${BLUE}============================================================${NC}

${BOLD}${BLUE}3x-ui / x-ui panel${NC}
  ${BOLD}${BLUE}URL:${NC}      ${BLUE}${xui_url}${NC}
  ${BOLD}${BLUE}Login:${NC}    ${BLUE}${xui_user:-check with: x-ui settings}${NC}
  ${BOLD}${BLUE}Password:${NC} ${BLUE}${xui_pass:-check with: x-ui settings}${NC}

${BOLD}${BLUE}N+H Panel${NC}
  ${BOLD}${BLUE}URL:${NC}      ${BLUE}${nh_panel_url}${NC}
  ${BOLD}${BLUE}Login:${NC}    ${BLUE}${nh_panel_login}${NC}
  ${BOLD}${BLUE}Password:${NC} ${BLUE}${nh_panel_password}${NC}

${BOLD}${BLUE}NaiveProxy${NC}
  ${BOLD}${BLUE}Login:${NC}    ${BLUE}${naive_login:-check config.env}${NC}
  ${BOLD}${BLUE}Password:${NC} ${BLUE}${naive_password:-check config.env}${NC}

${BOLD}${BLUE}Hysteria2${NC}
  ${BOLD}${BLUE}User:${NC}     ${BLUE}${hy2_user:-check config.env}${NC}
  ${BOLD}${BLUE}Password:${NC} ${BLUE}${hy2_password:-check config.env}${NC}

${BOLD}${BLUE}Saved copy-friendly file:${NC}
  ${BLUE}${SUMMARY_FILE}${NC}

EOF
