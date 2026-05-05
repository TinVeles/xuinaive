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
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
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
naive_link="$(config_value NH_NAIVE_LINK)"
hy2_link="$(config_value NH_HY2_LINK)"

subscription_token=""
if [[ -f /etc/nh-panel/subscription-token ]]; then
  subscription_token="$(tr -dc 'A-Za-z0-9._-' < /etc/nh-panel/subscription-token | head -c 128)"
fi
if [[ -n "$subscription_token" ]]; then
  sub_base="${nh_panel_url%/}/sub/${subscription_token}"
else
  sub_base="${nh_panel_url%/}/sub"
fi
warp_host="$(config_value WARP_PROXY_HOST)"; [[ -n "$warp_host" ]] || warp_host="127.0.0.1"
warp_port="$(config_value WARP_PROXY_PORT)"; [[ -n "$warp_port" ]] || warp_port="40000"
warp_snippet="$(config_value WARP_SNIPPET_FILE)"; [[ -n "$warp_snippet" ]] || warp_snippet="/etc/x-ui/warp-xray-snippets.json"
if command -v warp-cli >/dev/null 2>&1; then
  warp_status="$(warp-cli --accept-tos status 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
else
  warp_status="not installed"
fi

services_block="$(for svc in x-ui nginx caddy-nh panel-naive-hy2 hysteria-server warp-svc; do printf '  %-18s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"; done)"

cat > "$SUMMARY_FILE" <<EOF
xuinaive - final access info
============================

3x-ui / x-ui panel
URL:      ${xui_url}
Login:    ${xui_user:-check with: x-ui settings}
Password: ${xui_pass:-check with: x-ui settings}

N+H Panel
URL:      ${nh_panel_url}
Login:    ${nh_panel_login}
Password: ${nh_panel_password}

Proxy links
Naive: ${naive_link:-not available}
Hy2:   ${hy2_link:-not available}

Subscriptions
Naive:    ${sub_base}/naive.txt
Hy2:      ${sub_base}/hy2.txt
All:      ${sub_base}/all.txt
sing-box: ${sub_base}/sing-box.json

WARP
Status:  ${warp_status}
Proxy:   ${warp_host}:${warp_port}
Snippet: ${warp_snippet}

Reports
x-ui clients: /etc/x-ui/generated-clients.txt
N+H links:    /opt/panel-naive-hy2/generated-profiles.txt

Services
${services_block}
EOF
chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

cat <<EOF

${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}
${BOLD}${GREEN}║                    XUINAIVE READY TO CONNECT                        ║${NC}
${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}

${BOLD}${CYAN}3x-ui / x-ui panel${NC}
  ${BOLD}URL:${NC}      ${xui_url}
  ${BOLD}Login:${NC}    ${xui_user:-check with: x-ui settings}
  ${BOLD}Password:${NC} ${xui_pass:-check with: x-ui settings}

${BOLD}${MAGENTA}N+H Panel${NC}
  ${BOLD}URL:${NC}      ${nh_panel_url}
  ${BOLD}Login:${NC}    ${nh_panel_login}
  ${BOLD}Password:${NC} ${nh_panel_password}

${BOLD}${YELLOW}Proxy Links${NC}
  ${BOLD}Naive:${NC} ${naive_link:-not available}
  ${BOLD}Hy2:${NC}   ${hy2_link:-not available}

${BOLD}${BLUE}Subscriptions${NC}
  ${BOLD}Naive:${NC}    ${sub_base}/naive.txt
  ${BOLD}Hy2:${NC}      ${sub_base}/hy2.txt
  ${BOLD}All:${NC}      ${sub_base}/all.txt
  ${BOLD}sing-box:${NC} ${sub_base}/sing-box.json

${BOLD}${CYAN}WARP${NC}
  ${BOLD}Status:${NC}  ${warp_status}
  ${BOLD}Proxy:${NC}   ${warp_host}:${warp_port}
  ${BOLD}Snippet:${NC} ${warp_snippet}

${BOLD}${GREEN}Reports${NC}
  x-ui clients: /etc/x-ui/generated-clients.txt
  N+H links:    /opt/panel-naive-hy2/generated-profiles.txt

${BOLD}${GREEN}Services${NC}
${services_block}

${BOLD}Saved copy-friendly file:${NC}
  ${SUMMARY_FILE}

EOF
