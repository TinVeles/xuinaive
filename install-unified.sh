#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
XUI_DOMAIN=""
NAIVE_DOMAIN=""
NH_DOMAIN=""
REALITY_DEST=""
NAIVE_EMAIL=""
NH_EMAIL=""
ASSUME_YES=0
NH_BACKEND="127.0.0.1:9445"
PANEL_ACCESS="nginx8080"
PANEL_PUBLIC_PORT="8081"
TLS_CERT=""
TLS_KEY=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified.sh --mode all \
    --xui-domain xui.example.com \
    --nh-domain naive.example.com \
    --reality-dest reality.example.com \
    --nh-email admin@example.com \
    [--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem] \
    --yes

This is the explicit real installer. It runs vendored component scripts.
For dry-run checks use ./install.sh.
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_active() {
  local svc="$1"
  if ! systemctl is-active --quiet "$svc"; then
    printf 'ERROR: %s failed to start\n' "$svc" >&2
    journalctl -u "$svc" -n 80 --no-pager -l >&2 || true
    exit 1
  fi
  ok "$svc is active"
}

config_value() {
  local key="$1"
  local file="${2:-$SCRIPT_DIR/config.env}"
  [[ -f "$file" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "$file" 2>/dev/null || true
}

xui_setting() {
  local key="$1"
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 -noheader -batch /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null || true
  fi
}

public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  printf '%s\n' "$ip"
}

write_access_summary() {
  local summary_file="$SCRIPT_DIR/access-info.txt"
  local server_ip xui_user xui_pass xui_port xui_path xui_url nh_panel_url
  local naive_link hy2_link nh_panel_login nh_panel_password

  server_ip="$(public_ipv4)"
  [[ -n "$server_ip" ]] || server_ip="SERVER_IP"

  xui_user="$(xui_setting username)"
  xui_pass="$(xui_setting password)"
  xui_port="$(xui_setting webPort)"
  xui_path="$(xui_setting webBasePath)"
  xui_path="${xui_path#/}"
  xui_path="${xui_path%/}"
  if [[ -n "$xui_path" ]]; then
    xui_url="https://${XUI_DOMAIN}/${xui_path}/"
  else
    xui_url="https://${XUI_DOMAIN}/"
  fi
  [[ -n "$xui_port" ]] || xui_port="443 via nginx"

  nh_panel_url="$(config_value NH_PANEL_URL)"
  nh_panel_url="${nh_panel_url/SERVER_IP/$server_ip}"
  [[ -n "$nh_panel_url" ]] || nh_panel_url="http://${server_ip}:${PANEL_PUBLIC_PORT}"
  nh_panel_login="$(config_value NH_PANEL_LOGIN)"
  nh_panel_password="$(config_value NH_PANEL_PASSWORD)"
  naive_link="$(config_value NH_NAIVE_LINK)"
  hy2_link="$(config_value NH_HY2_LINK)"

  cat > "$summary_file" <<EOF
============================================================
Unified Proxy Manager - Access Info
============================================================

3x-ui / x-ui panel
------------------------------------------------------------
URL:      ${xui_url}
Login:    ${xui_user:-check with: x-ui settings}
Password: ${xui_pass:-check with: x-ui settings}
Port:     ${xui_port}

Copy:
${xui_url}
${xui_user:-}
${xui_pass:-}

N+H Panel
------------------------------------------------------------
URL:      ${nh_panel_url}
Login:    ${nh_panel_login:-admin}
Password: ${nh_panel_password:-admin}

Copy:
${nh_panel_url}
${nh_panel_login:-admin}
${nh_panel_password:-admin}

NaiveProxy
------------------------------------------------------------
Domain:   ${NH_DOMAIN}
Backend:  ${NH_BACKEND}
Link:
${naive_link:-not available}

Hysteria2
------------------------------------------------------------
Link:
${hy2_link:-not available}

Useful commands
------------------------------------------------------------
Show this file:
  sudo cat ${summary_file}

Project status:
  cd ${SCRIPT_DIR}
  sudo ./status.sh

Diagnostics:
  cd ${SCRIPT_DIR}
  sudo ./doctor.sh

Services:
  sudo systemctl status x-ui nginx caddy-nh panel-naive-hy2 hysteria-server --no-pager

Security notes
------------------------------------------------------------
- Change the default N+H Panel password admin/admin after first login.
- Keep this file private: it contains panel credentials and proxy links.
EOF
  chmod 600 "$summary_file" 2>/dev/null || true

  cat <<EOF

╔════════════════════════════════════════════════════════════╗
║                INSTALLATION ACCESS INFO                  ║
╚════════════════════════════════════════════════════════════╝

3x-ui / x-ui panel
  URL:      ${xui_url}
  Login:    ${xui_user:-check with: x-ui settings}
  Password: ${xui_pass:-check with: x-ui settings}

N+H Panel
  URL:      ${nh_panel_url}
  Login:    ${nh_panel_login:-admin}
  Password: ${nh_panel_password:-admin}

NaiveProxy link
  ${naive_link:-not available}

Hysteria2 link
  ${hy2_link:-not available}

Saved copy-friendly file:
  ${summary_file}

Show it again:
  sudo cat ${summary_file}

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --xui-domain) XUI_DOMAIN="${2:-}"; shift 2 ;;
    --naive-domain) NAIVE_DOMAIN="${2:-}"; shift 2 ;;
    --nh-domain) NH_DOMAIN="${2:-}"; shift 2 ;;
    --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
    --naive-email) NAIVE_EMAIL="${2:-}"; shift 2 ;;
    --nh-email) NH_EMAIL="${2:-}"; shift 2 ;;
    --naive-backend) NH_BACKEND="${2:-}"; shift 2 ;;
    --nh-backend) NH_BACKEND="${2:-}"; shift 2 ;;
    --panel-access) PANEL_ACCESS="${2:-}"; shift 2 ;;
    --panel-public-port) PANEL_PUBLIC_PORT="${2:-}"; shift 2 ;;
    --tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key) TLS_KEY="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$MODE" == "all" || "$MODE" == "both" ]] || die "This real unified installer supports --mode all"
[[ -n "$NH_DOMAIN" ]] || NH_DOMAIN="$NAIVE_DOMAIN"
[[ -n "$NH_EMAIL" ]] || NH_EMAIL="$NAIVE_EMAIL"
[[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required"
[[ -n "$NH_DOMAIN" ]] || die "--nh-domain is required"
[[ -n "$REALITY_DEST" ]] || die "--reality-dest is required"
[[ -n "$NH_EMAIL" ]] || die "--nh-email is required"
if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
  [[ -f "$TLS_CERT" ]] || die "--tls-cert file not found: $TLS_CERT"
  [[ -f "$TLS_KEY" ]] || die "--tls-key file not found: $TLS_KEY"
fi
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading the plan. This installer runs destructive upstream x-ui-pro code."

XUI_SCRIPT="$SCRIPT_DIR/components/x-ui-pro/x-ui-pro.sh"
SNI_PATCH="$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh"
NH_BACKEND_INSTALL="$SCRIPT_DIR/components/nh-panel/install-unified-backend.sh"

[[ -f "$XUI_SCRIPT" ]] || die "Missing $XUI_SCRIPT"
[[ -f "$SNI_PATCH" ]] || die "Missing $SNI_PATCH"
[[ -f "$NH_BACKEND_INSTALL" ]] || die "Missing $NH_BACKEND_INSTALL"

cat <<EOF
Final configuration
-------------------
XUI domain:          ${XUI_DOMAIN}
N+H/Naive domain: ${NH_DOMAIN}
Reality dest:        ${REALITY_DEST}
N+H email:         ${NH_EMAIL}
Panel port:          ${PANEL_PUBLIC_PORT}
Backend listen:      ${NH_BACKEND}
TLS cert:            ${TLS_CERT:-auto/ACME}
TLS key:             ${TLS_KEY:-auto/ACME}

Unified all-in-one real install plan
------------------------------------
1. Run vendored x-ui-pro installer.
   Public nginx stream will own 0.0.0.0:443.
2. Patch /etc/nginx/stream-enabled/stream.conf:
   ${NH_DOMAIN} -> ${NH_BACKEND}
3. Install N+H Panel + NaiveProxy + Hysteria2:
   caddy-nh binds ${NH_BACKEND} for TCP NaiveProxy.
   hysteria-server binds 0.0.0.0:443/udp.
   panel-naive-hy2 is exposed with panel access mode ${PANEL_ACCESS} on port ${PANEL_PUBLIC_PORT}.

WARNING:
The vendored x-ui-pro script is still destructive like upstream:
it removes existing x-ui and nginx configs and kills listeners on 80/443.
EOF

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in /etc/nginx /etc/x-ui /usr/local/x-ui /etc/caddy-nh /etc/hysteria /opt/panel-naive-hy2 /etc/systemd/system/x-ui.service /etc/systemd/system/caddy-nh.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/panel-naive-hy2.service; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
ok "Backup directory: $backup_dir"

info "Running x-ui-pro installer"
bash "$XUI_SCRIPT" -install yes -panel 1 -subdomain "$XUI_DOMAIN" -reality_domain "$REALITY_DEST"
require_active x-ui
require_active nginx

info "Adding nginx stream route for N+H NaiveProxy"
bash "$SNI_PATCH" --domain "$NH_DOMAIN" --backend "$NH_BACKEND" --name nh_naive

info "Installing N+H Panel + NaiveProxy + Hysteria2 backend"
nh_args=(
  --domain "$NH_DOMAIN"
  --email "$NH_EMAIL"
  --listen "$NH_BACKEND"
  --panel-access "$PANEL_ACCESS"
  --panel-public-port "$PANEL_PUBLIC_PORT"
)
[[ -n "$TLS_CERT" ]] && nh_args+=(--tls-cert "$TLS_CERT")
[[ -n "$TLS_KEY" ]] && nh_args+=(--tls-key "$TLS_KEY")
bash "$NH_BACKEND_INSTALL" "${nh_args[@]}"

require_active caddy-nh
require_active hysteria-server
require_active panel-naive-hy2

NH_TLS_CERT_FINAL="${TLS_CERT}"
NH_TLS_KEY_FINAL="${TLS_KEY}"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  [[ -n "$NH_TLS_CERT_FINAL" ]] || NH_TLS_CERT_FINAL="$(awk -F= '/^NH_TLS_CERT=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$SCRIPT_DIR/config.env" 2>/dev/null || true)"
  [[ -n "$NH_TLS_KEY_FINAL" ]] || NH_TLS_KEY_FINAL="$(awk -F= '/^NH_TLS_KEY=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$SCRIPT_DIR/config.env" 2>/dev/null || true)"
fi
NH_PANEL_URL_FINAL="$(config_value NH_PANEL_URL)"
NH_PANEL_LOGIN_FINAL="$(config_value NH_PANEL_LOGIN)"
NH_PANEL_PASSWORD_FINAL="$(config_value NH_PANEL_PASSWORD)"
NH_NAIVE_LOGIN_FINAL="$(config_value NH_NAIVE_LOGIN)"
NH_NAIVE_PASSWORD_FINAL="$(config_value NH_NAIVE_PASSWORD)"
NH_NAIVE_LINK_FINAL="$(config_value NH_NAIVE_LINK)"
NH_HY2_USER_FINAL="$(config_value NH_HY2_USER)"
NH_HY2_PASSWORD_FINAL="$(config_value NH_HY2_PASSWORD)"
NH_HY2_LINK_FINAL="$(config_value NH_HY2_LINK)"

cat > "$SCRIPT_DIR/config.env" <<EOF
XUI_DOMAIN="${XUI_DOMAIN}"
NAIVE_DOMAIN="${NH_DOMAIN}"
REALITY_DEST="${REALITY_DEST}"
NH_PROXY_DOMAIN="${NH_DOMAIN}"
NH_PANEL_DOMAIN=""
NH_EMAIL="${NH_EMAIL}"
NH_PANEL_PORT="${PANEL_PUBLIC_PORT}"
NH_BACKEND_LISTEN="${NH_BACKEND}"
NH_TLS_CERT="${NH_TLS_CERT_FINAL}"
NH_TLS_KEY="${NH_TLS_KEY_FINAL}"
NH_PANEL_URL="${NH_PANEL_URL_FINAL}"
NH_PANEL_LOGIN="${NH_PANEL_LOGIN_FINAL}"
NH_PANEL_PASSWORD="${NH_PANEL_PASSWORD_FINAL}"
NH_NAIVE_LOGIN="${NH_NAIVE_LOGIN_FINAL}"
NH_NAIVE_PASSWORD="${NH_NAIVE_PASSWORD_FINAL}"
NH_NAIVE_LINK="${NH_NAIVE_LINK_FINAL}"
NH_HY2_USER="${NH_HY2_USER_FINAL}"
NH_HY2_PASSWORD="${NH_HY2_PASSWORD_FINAL}"
NH_HY2_LINK="${NH_HY2_LINK_FINAL}"
EOF
ok "Saved final configuration: $SCRIPT_DIR/config.env"

ok "Unified install completed"
systemctl status x-ui --no-pager || true
systemctl status nginx --no-pager || true
systemctl status caddy-nh --no-pager || true
systemctl status hysteria-server --no-pager || true
systemctl status panel-naive-hy2 --no-pager || true
write_access_summary
