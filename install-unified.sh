#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
XUI_DOMAIN=""
NAIVE_DOMAIN=""
RIXXX_DOMAIN=""
REALITY_DEST=""
NAIVE_EMAIL=""
RIXXX_EMAIL=""
ASSUME_YES=0
RIXXX_BACKEND="127.0.0.1:9445"
PANEL_ACCESS="nginx8080"
PANEL_PUBLIC_PORT="8081"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified.sh --mode all \
    --xui-domain xui.example.com \
    --rixxx-domain naive.example.com \
    --reality-dest reality.example.com \
    --rixxx-email admin@example.com \
    --yes

This is the explicit real installer. It runs vendored component scripts.
For dry-run checks use ./install.sh.
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --xui-domain) XUI_DOMAIN="${2:-}"; shift 2 ;;
    --naive-domain) NAIVE_DOMAIN="${2:-}"; shift 2 ;;
    --rixxx-domain) RIXXX_DOMAIN="${2:-}"; shift 2 ;;
    --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
    --naive-email) NAIVE_EMAIL="${2:-}"; shift 2 ;;
    --rixxx-email) RIXXX_EMAIL="${2:-}"; shift 2 ;;
    --naive-backend) RIXXX_BACKEND="${2:-}"; shift 2 ;;
    --rixxx-backend) RIXXX_BACKEND="${2:-}"; shift 2 ;;
    --panel-access) PANEL_ACCESS="${2:-}"; shift 2 ;;
    --panel-public-port) PANEL_PUBLIC_PORT="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$MODE" == "all" || "$MODE" == "both" ]] || die "This real unified installer supports --mode all"
[[ -n "$RIXXX_DOMAIN" ]] || RIXXX_DOMAIN="$NAIVE_DOMAIN"
[[ -n "$RIXXX_EMAIL" ]] || RIXXX_EMAIL="$NAIVE_EMAIL"
[[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required"
[[ -n "$RIXXX_DOMAIN" ]] || die "--rixxx-domain is required"
[[ -n "$REALITY_DEST" ]] || die "--reality-dest is required"
[[ -n "$RIXXX_EMAIL" ]] || die "--rixxx-email is required"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading the plan. This installer runs destructive upstream x-ui-pro code."

XUI_SCRIPT="$SCRIPT_DIR/components/x-ui-pro/x-ui-pro.sh"
SNI_PATCH="$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh"
RIXXX_BACKEND_INSTALL="$SCRIPT_DIR/components/rixxx-panel/install-unified-backend.sh"

[[ -f "$XUI_SCRIPT" ]] || die "Missing $XUI_SCRIPT"
[[ -f "$SNI_PATCH" ]] || die "Missing $SNI_PATCH"
[[ -f "$RIXXX_BACKEND_INSTALL" ]] || die "Missing $RIXXX_BACKEND_INSTALL"

cat <<EOF
Unified all-in-one real install plan
------------------------------------
1. Run vendored x-ui-pro installer.
   Public nginx stream will own 0.0.0.0:443.
2. Patch /etc/nginx/stream-enabled/stream.conf:
   ${RIXXX_DOMAIN} -> ${RIXXX_BACKEND}
3. Install RIXXX Panel + NaiveProxy + Hysteria2:
   caddy-rixxx binds ${RIXXX_BACKEND} for TCP NaiveProxy.
   hysteria-server binds 0.0.0.0:443/udp.
   panel-naive-hy2 is exposed with panel access mode ${PANEL_ACCESS} on port ${PANEL_PUBLIC_PORT}.

WARNING:
The vendored x-ui-pro script is still destructive like upstream:
it removes existing x-ui and nginx configs and kills listeners on 80/443.
EOF

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in /etc/nginx /etc/x-ui /usr/local/x-ui /etc/caddy-rixxx /etc/hysteria /opt/panel-naive-hy2 /etc/systemd/system/x-ui.service /etc/systemd/system/caddy-rixxx.service /etc/systemd/system/hysteria-server.service /etc/systemd/system/panel-naive-hy2.service; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
ok "Backup directory: $backup_dir"

info "Running x-ui-pro installer"
bash "$XUI_SCRIPT" -install yes -panel 1 -subdomain "$XUI_DOMAIN" -reality_domain "$REALITY_DEST"

info "Adding nginx stream route for RIXXX NaiveProxy"
bash "$SNI_PATCH" --domain "$RIXXX_DOMAIN" --backend "$RIXXX_BACKEND" --name rixxx_naive

info "Installing RIXXX Panel + NaiveProxy + Hysteria2 backend"
bash "$RIXXX_BACKEND_INSTALL" --domain "$RIXXX_DOMAIN" --email "$RIXXX_EMAIL" --listen "$RIXXX_BACKEND" --panel-access "$PANEL_ACCESS" --panel-public-port "$PANEL_PUBLIC_PORT"

ok "Unified install completed"
systemctl status x-ui --no-pager || true
systemctl status nginx --no-pager || true
systemctl status caddy-rixxx --no-pager || true
systemctl status hysteria-server --no-pager || true
systemctl status panel-naive-hy2 --no-pager || true
