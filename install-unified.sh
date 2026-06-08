#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/warp.sh"

MODE=""
XUI_DOMAIN=""
NAIVE_DOMAIN=""
NH_DOMAIN=""
REALITY_DEST=""
NAIVE_EMAIL=""
NH_EMAIL=""
ASSUME_YES=0
NH_BACKEND="127.0.0.1:9445"
PANEL_ACCESS="ssh-tunnel"
PANEL_PUBLIC_PORT="8081"
TLS_CERT=""
TLS_KEY=""
GENERATE_PROFILES="${GENERATE_PROFILES:-1}"
PROFILE_COUNT=15
PROFILE_PREFIX="auto"
WARP_PROXY_PORT=40000
WARP_OUTBOUND_TAG="warp-cli"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-all}"
WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}"
AUTO_INSTALL_WARP="${AUTO_INSTALL_WARP:-0}"
XUI_ENABLE_WARP_ROUTING="${XUI_ENABLE_WARP_ROUTING:-0}"
XUI_APPLY_WARP_TEMPLATE="${XUI_APPLY_WARP_TEMPLATE:-0}"
XUI_CREATE_DIRECT="${XUI_CREATE_DIRECT:-1}"
XUI_HY2_PUBLIC_PORT="${XUI_HY2_PUBLIC_PORT:-24443}"
XUI_PANEL_LINE="${XUI_PANEL_LINE:-legacy}"
PRINT_ACCESS_INFO=1
NH_ENABLE_MIERU=0
ALLOW_DESTROY_EXISTING="${UPM_ALLOW_DESTROY_EXISTING:-0}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified.sh --mode all \
    --xui-domain xui.example.com \
    --nh-domain naive.example.com \
    --reality-dest reality.example.com \
    --nh-email admin@example.com \
    [--xui-panel-line legacy|latest] \
    [--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem] \
    [--with-mieru] \
    [--install-warp] \
    [--no-install-warp] \
    [--allow-destroy-existing] \
    --yes

This is the explicit real installer. It runs vendored component scripts.
It generates profiles/subscriptions by default. Add --install-warp to install WARP and enable AI routing through it.
Naive+Mieru is installed through RIXXX Panel. Hysteria2 panel backend is no longer installed.
The default x-ui panel line is legacy 2.9.4. Use --xui-panel-line latest for upstream 3x-ui v3 with SQLite.
For dry-run checks use ./install.sh.
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  NC=$'\033[0m'
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
  NC=""
fi

reset_terminal_style() {
  [[ -t 1 ]] && printf '\033[0m\033[24m\033[25m' || true
}
trap reset_terminal_style EXIT
reset_terminal_style

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
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "$file" 2>/dev/null || true
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

config_set() {
  local key="$1" value="$2" file="${3:-$SCRIPT_DIR/config.env}" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    grep -vE "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$(env_quote "$value")" >> "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

xui_setting() {
  local key="$1"
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f /etc/x-ui/x-ui.db ]]; then
    sqlite3 -noheader -batch /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" 2>/dev/null || true
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

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && ${#1} -le 253 ]]
}

is_valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ && ${#1} -le 254 ]]
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

is_valid_hostport() {
  local host="${1%:*}" port="${1##*:}"
  [[ -n "$host" && "$host" != "$1" ]] || return 1
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^localhost$|^[A-Za-z0-9_.-]+$ ]] || return 1
  is_valid_port "$port"
}

write_access_summary() {
  bash "$SCRIPT_DIR/show-access-info.sh"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --xui-domain) XUI_DOMAIN="${2:-}"; shift 2 ;;
    --xui-panel-line) XUI_PANEL_LINE="${2:-}"; shift 2 ;;
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
    --generate-profiles) GENERATE_PROFILES=1; shift ;;
    --no-generate-profiles) GENERATE_PROFILES=0; shift ;;
    --profile-count) PROFILE_COUNT="${2:-}"; shift 2 ;;
    --profile-prefix) PROFILE_PREFIX="${2:-}"; shift 2 ;;
    --warp-proxy-port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --warp-outbound-tag) WARP_OUTBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-inbound-tag) WARP_INBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-ai-domains) WARP_AI_DOMAINS="${2:-}"; shift 2 ;;
    --install-warp) AUTO_INSTALL_WARP=1; XUI_ENABLE_WARP_ROUTING=1; shift ;;
    --no-install-warp) AUTO_INSTALL_WARP=0; XUI_ENABLE_WARP_ROUTING=0; shift ;;
    --no-auto-install-warp) AUTO_INSTALL_WARP=0; shift ;;
    --auto-install-warp) AUTO_INSTALL_WARP=1; shift ;;
    --no-xui-warp-routing) XUI_ENABLE_WARP_ROUTING=0; shift ;;
    --xui-warp-routing) XUI_ENABLE_WARP_ROUTING=1; shift ;;
    --apply-xui-warp-template) XUI_APPLY_WARP_TEMPLATE=1; shift ;;
    --no-apply-xui-warp-template) XUI_APPLY_WARP_TEMPLATE=0; shift ;;
    --with-mieru|--enable-mieru) NH_ENABLE_MIERU=1; shift ;;
    --no-access-info) PRINT_ACCESS_INFO=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-destroy-existing) ALLOW_DESTROY_EXISTING=1; shift ;;
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
is_valid_domain "$XUI_DOMAIN" || die "--xui-domain is invalid: $XUI_DOMAIN"
is_valid_domain "$NH_DOMAIN" || die "--nh-domain is invalid: $NH_DOMAIN"
is_valid_domain "$REALITY_DEST" || die "--reality-dest is invalid: $REALITY_DEST"
is_valid_email "$NH_EMAIL" || die "--nh-email is invalid: $NH_EMAIL"
is_valid_port "$PANEL_PUBLIC_PORT" || die "--panel-public-port must be 1..65535"
is_valid_port "$XUI_HY2_PUBLIC_PORT" || die "XUI_HY2_PUBLIC_PORT must be 1..65535"
[[ "$XUI_PANEL_LINE" == "legacy" || "$XUI_PANEL_LINE" == "latest" ]] || die "--xui-panel-line must be legacy or latest"
is_valid_hostport "$NH_BACKEND" || die "--nh-backend must be safe host:port"
if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
  [[ -f "$TLS_CERT" ]] || die "--tls-cert file not found: $TLS_CERT"
  [[ -f "$TLS_KEY" ]] || die "--tls-key file not found: $TLS_KEY"
  [[ -r "$TLS_CERT" ]] || die "--tls-cert is not readable: $TLS_CERT"
  [[ -r "$TLS_KEY" ]] || die "--tls-key is not readable: $TLS_KEY"
fi
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading the plan. This installer runs destructive upstream x-ui-pro code."
[[ "$PROFILE_COUNT" =~ ^[0-9]+$ && "$PROFILE_COUNT" -gt 0 ]] || die "--profile-count must be a positive number"
[[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--warp-proxy-port must be numeric"

XUI_SCRIPT="$SCRIPT_DIR/components/x-ui-pro/x-ui-pro.sh"
SNI_PATCH="$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh"
NH_BACKEND_INSTALL="$SCRIPT_DIR/components/rixxx-panel/install-unified-backend.sh"

[[ -f "$XUI_SCRIPT" ]] || die "Missing $XUI_SCRIPT"
[[ -f "$SNI_PATCH" ]] || die "Missing $SNI_PATCH"
[[ -f "$NH_BACKEND_INSTALL" ]] || die "Missing $NH_BACKEND_INSTALL"

cat <<EOF
Final configuration
-------------------
XUI domain:          ${XUI_DOMAIN}
RIXXX domain:       ${NH_DOMAIN}
Reality dest:        ${REALITY_DEST}
RIXXX email:        ${NH_EMAIL}
x-ui line:           ${XUI_PANEL_LINE}
Panel port:          ${PANEL_PUBLIC_PORT}
Backend listen:      ${NH_BACKEND}
x-ui Hysteria2 UDP:  ${XUI_HY2_PUBLIC_PORT}
Mieru module:        enabled
TLS cert:            ${TLS_CERT:-auto/ACME}
TLS key:             ${TLS_KEY:-auto/ACME}

Unified all-in-one real install plan
------------------------------------
1. Run vendored x-ui-pro installer.
   Public nginx stream will own 0.0.0.0:443.
2. Patch /etc/nginx/stream-enabled/stream.conf:
   ${NH_DOMAIN} -> ${NH_BACKEND}
3. Install RIXXX Panel + NaiveProxy + Mieru:
   caddy-naive binds backend port ${NH_BACKEND##*:} for TCP NaiveProxy.
   Mieru binds its own public TCP/UDP port range.
   x-ui Hysteria2 keeps its separate ${XUI_HY2_PUBLIC_PORT}/udp listener.
   panel-naive-mieru is exposed with panel access mode ${PANEL_ACCESS} on port ${PANEL_PUBLIC_PORT}.
4. Install WARP local proxy only when --install-warp is enabled.
5. Generate x-ui profiles when enabled. RIXXX users are managed by its panel.

WARNING:
The vendored x-ui-pro script is still destructive like upstream:
it removes existing x-ui and nginx configs before recreating them.
EOF

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in /etc/nginx /etc/x-ui /usr/local/x-ui /etc/caddy-nh /etc/hysteria /opt/panel-naive-hy2 /etc/caddy-naive /etc/rixxx-panel /opt/panel-naive-mieru /var/lib/rixxx-panel /etc/systemd/system/x-ui.service /etc/systemd/system/caddy-nh.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/panel-naive-hy2.service /etc/systemd/system/caddy-naive.service /etc/systemd/system/mita.service; do
  if [[ -e "$path" || -L "$path" ]]; then
    parent_dir="$(dirname "$path")"
    mkdir -p "$backup_dir$parent_dir"
    cp -aT "$path" "$backup_dir$path"
  fi
done
ok "Backup directory: $backup_dir"

UPM_ALLOW_DESTROY_EXISTING="$ALLOW_DESTROY_EXISTING" confirm_destructive "x-ui-pro upstream installer (will rm /usr/local/x-ui /etc/x-ui and kill 80/443 listeners)"

XUI_VERIFIER="$SCRIPT_DIR/components/x-ui-pro/verify-upstream-binaries.sh"
XUI_RELEASE_CHANNEL="legacy"
XUI_VERSION_OVERRIDE="v2.9.4"
if [[ "$XUI_PANEL_LINE" == "latest" ]]; then
  XUI_RELEASE_CHANNEL="latest"
  XUI_VERSION_OVERRIDE=""
  install -d -m 0755 /etc/default
  printf 'XUI_DB_TYPE=sqlite\n' > /etc/default/x-ui
  chmod 0600 /etc/default/x-ui
fi
if [[ -x "$XUI_VERIFIER" ]]; then
  info "Pre-fetching and SHA256-verifying x-ui-pro upstream artifacts"
  XUI_RUNTIME_SCRIPT="$(UPM_X_UI_RELEASE_CHANNEL="$XUI_RELEASE_CHANNEL" UPM_X_UI_VERSION_OVERRIDE="$XUI_VERSION_OVERRIDE" bash "$XUI_VERIFIER" | tail -n1)"
  [[ -x "$XUI_RUNTIME_SCRIPT" ]] || die "verify-upstream-binaries.sh did not produce a runnable patched script"
else
  if [[ "${UPM_SKIP_UPSTREAM_VERIFY:-0}" != "1" ]]; then
    warn "Missing verifier: $XUI_VERIFIER"
    warn "Skipping SHA256 verification. Set UPM_SKIP_UPSTREAM_VERIFY=1 to silence this warning."
    warn "Fetch the verifier (recommended): scp components/x-ui-pro/verify-upstream-binaries.sh root@HOST:$SCRIPT_DIR/components/x-ui-pro/"
  fi
  XUI_RUNTIME_SCRIPT="$XUI_SCRIPT"
fi

info "Running x-ui-pro installer (verified copy)"
XUI_PRINT_ACCESS_INFO=0 \
XUI_VERSION="$XUI_VERSION_OVERRIDE" \
XUI_DB_TYPE=sqlite \
XUI_SEED_PROFILES=0 \
XUI_PROFILE_COUNT="$PROFILE_COUNT" \
XUI_PROFILE_PREFIX="$PROFILE_PREFIX" \
XUI_ENABLE_WARP_ROUTING="$XUI_ENABLE_WARP_ROUTING" \
XUI_APPLY_WARP_TEMPLATE="$XUI_APPLY_WARP_TEMPLATE" \
XUI_CREATE_DIRECT_CLIENTS="$XUI_CREATE_DIRECT" \
HY2_PUBLIC_PORT="$XUI_HY2_PUBLIC_PORT" \
UPM_ALLOW_DESTROY_EXISTING="$ALLOW_DESTROY_EXISTING" \
WARP_INBOUND_TAG="$WARP_INBOUND_TAG" \
bash "$XUI_RUNTIME_SCRIPT" -install yes -panel 1 -subdomain "$XUI_DOMAIN" -reality_domain "$REALITY_DEST"
require_active x-ui
require_active nginx
upm_assert_xui_creds_rotated /etc/x-ui/x-ui.db
[[ -f /etc/x-ui/access-info.env ]] && chmod 0600 /etc/x-ui/access-info.env 2>/dev/null || true
if [[ "$AUTO_INSTALL_WARP" == "1" && "$XUI_ENABLE_WARP_ROUTING" == "1" ]]; then
  ensure_warp_local_proxy "$SCRIPT_DIR"
fi

info "Adding nginx stream route for RIXXX NaiveProxy"
bash "$SNI_PATCH" --domain "$NH_DOMAIN" --backend "$NH_BACKEND" --name nh_naive

info "Installing RIXXX Panel + NaiveProxy + Mieru backend"
nh_args=(
  --domain "$NH_DOMAIN"
  --email "$NH_EMAIL"
  --listen "$NH_BACKEND"
  --panel-access "$PANEL_ACCESS"
  --panel-public-port "$PANEL_PUBLIC_PORT"
)
[[ -n "$TLS_CERT" ]] && nh_args+=(--tls-cert "$TLS_CERT")
[[ -n "$TLS_KEY" ]] && nh_args+=(--tls-key "$TLS_KEY")
nh_args+=(--with-mieru)
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}" \
WARP_PROXY_PORT="$WARP_PROXY_PORT" \
WARP_OUTBOUND_TAG="$WARP_OUTBOUND_TAG" \
WARP_AI_DOMAINS="$WARP_AI_DOMAINS" \
bash "$NH_BACKEND_INSTALL" "${nh_args[@]}"

require_active caddy-naive
if systemctl is-active --quiet mita; then
  ok "mita is active"
else
  warn "mita is not active yet; RIXXX starts it after first Mieru user is created"
fi
if command -v pm2 >/dev/null 2>&1; then
  pm2 describe panel-naive-mieru >/dev/null 2>&1 || die "PM2 process panel-naive-mieru is missing"
  ok "panel-naive-mieru PM2 process exists"
fi

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
XUI_PANEL_URL_FINAL="$(config_value XUI_PANEL_URL /etc/x-ui/access-info.env)"
XUI_PANEL_LOGIN_FINAL="$(config_value XUI_PANEL_LOGIN /etc/x-ui/access-info.env)"
XUI_PANEL_PASSWORD_FINAL="$(config_value XUI_PANEL_PASSWORD /etc/x-ui/access-info.env)"

config_set XUI_DOMAIN "$XUI_DOMAIN"
config_set XUI_PANEL_LINE "$XUI_PANEL_LINE"
config_set XUI_PANEL_URL "$XUI_PANEL_URL_FINAL"
config_set XUI_PANEL_LOGIN "$XUI_PANEL_LOGIN_FINAL"
config_set XUI_PANEL_PASSWORD "$XUI_PANEL_PASSWORD_FINAL"
config_set NAIVE_DOMAIN "$NH_DOMAIN"
config_set REALITY_DEST "$REALITY_DEST"
config_set NH_PROXY_DOMAIN "$NH_DOMAIN"
config_set NH_PANEL_DOMAIN ""
config_set NH_EMAIL "$NH_EMAIL"
config_set NH_PANEL_PORT "$PANEL_PUBLIC_PORT"
config_set NH_BACKEND_LISTEN "$NH_BACKEND"
config_set NH_BACKEND_KIND "rixxx-naive-mieru"
config_set NH_ENABLE_MIERU "1"
config_set NH_TLS_CERT "$NH_TLS_CERT_FINAL"
config_set NH_TLS_KEY "$NH_TLS_KEY_FINAL"
config_set NH_PANEL_URL "$NH_PANEL_URL_FINAL"
config_set NH_PANEL_LOGIN "$NH_PANEL_LOGIN_FINAL"
config_set NH_PANEL_PASSWORD "$NH_PANEL_PASSWORD_FINAL"
config_set NH_NAIVE_LOGIN "$NH_NAIVE_LOGIN_FINAL"
config_set NH_NAIVE_PASSWORD "$NH_NAIVE_PASSWORD_FINAL"
config_set NH_NAIVE_LINK "$NH_NAIVE_LINK_FINAL"
config_set NH_HY2_USER "$NH_HY2_USER_FINAL"
config_set NH_HY2_PASSWORD "$NH_HY2_PASSWORD_FINAL"
config_set NH_HY2_LINK "$NH_HY2_LINK_FINAL"
config_set PROFILE_COUNT "$PROFILE_COUNT"
config_set PROFILE_PREFIX "$PROFILE_PREFIX"
config_set XUI_PROFILES_GENERATED "$GENERATE_PROFILES"
config_set WARP_ENABLED "$AUTO_INSTALL_WARP"
config_set WARP_PROXY_HOST "127.0.0.1"
config_set WARP_PROXY_PORT "$WARP_PROXY_PORT"
config_set WARP_OUTBOUND_TAG "$WARP_OUTBOUND_TAG"
config_set WARP_INBOUND_TAG "$WARP_INBOUND_TAG"
config_set WARP_AI_DOMAINS "$WARP_AI_DOMAINS"
config_set XUI_ENABLE_WARP_ROUTING "$XUI_ENABLE_WARP_ROUTING"
config_set XUI_APPLY_WARP_TEMPLATE "$XUI_APPLY_WARP_TEMPLATE"
config_set XUI_CREATE_DIRECT "$XUI_CREATE_DIRECT"
config_set XUI_HY2_PUBLIC_PORT "$XUI_HY2_PUBLIC_PORT"
ok "Saved final configuration: $SCRIPT_DIR/config.env"

if [[ "$GENERATE_PROFILES" == "1" ]]; then
  info "Running profile generation as part of unified install"
  if [[ "$XUI_PANEL_LINE" == "latest" ]]; then
    HY2_PUBLIC_PORT="$XUI_HY2_PUBLIC_PORT" \
    bash "$SCRIPT_DIR/generate-xui-v3.sh" \
      --reset-inbounds \
      --domain "$XUI_DOMAIN" \
      --reality-dest "$REALITY_DEST" \
      --count "${PROFILE_COUNT:-15}" \
      --prefix "${PROFILE_PREFIX:-auto}" \
      --yes
  else
    XUI_ENABLE_WARP_ROUTING="$XUI_ENABLE_WARP_ROUTING" \
    XUI_APPLY_WARP_TEMPLATE="$XUI_APPLY_WARP_TEMPLATE" \
    XUI_AUTO_INSTALL_WARP="$AUTO_INSTALL_WARP" \
    XUI_CREATE_DIRECT="$XUI_CREATE_DIRECT" \
    bash "$SCRIPT_DIR/generate-profiles.sh" \
      --xui-only \
      --count "${PROFILE_COUNT:-15}" \
      --prefix "${PROFILE_PREFIX:-auto}" \
      --warp-port "${WARP_PROXY_PORT:-40000}" \
      --warp-outbound-tag "${WARP_OUTBOUND_TAG:-warp-cli}" \
      --warp-inbound-tag "$WARP_INBOUND_TAG" \
      --warp-ai-domains "$WARP_AI_DOMAINS" \
      --yes
  fi
fi

ok "Unified install completed"
[[ "$PRINT_ACCESS_INFO" == "1" ]] && write_access_summary
