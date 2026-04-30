#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=""
XUI_DOMAIN=""
NAIVE_DOMAIN=""
REALITY_DEST=""
NAIVE_EMAIL=""
ASSUME_YES=0
NAIVE_BACKEND="127.0.0.1:9444"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified.sh --mode both \
    --xui-domain zaiki.example.com \
    --naive-domain sub.example.com \
    --reality-dest example.com \
    --naive-email admin@example.com \
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
    --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
    --naive-email) NAIVE_EMAIL="${2:-}"; shift 2 ;;
    --naive-backend) NAIVE_BACKEND="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$MODE" == "both" ]] || die "This first real unified installer supports --mode both only"
[[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required"
[[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required"
[[ -n "$REALITY_DEST" ]] || die "--reality-dest is required"
[[ -n "$NAIVE_EMAIL" ]] || die "--naive-email is required"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading the plan. This installer runs destructive upstream x-ui-pro code."

XUI_SCRIPT="$SCRIPT_DIR/components/x-ui-pro/x-ui-pro.sh"
SNI_PATCH="$SCRIPT_DIR/components/x-ui-pro/apply-naive-sni-route.sh"
NAIVE_BACKEND_INSTALL="$SCRIPT_DIR/components/naiveproxy/install.sh"

[[ -f "$XUI_SCRIPT" ]] || die "Missing $XUI_SCRIPT"
[[ -f "$SNI_PATCH" ]] || die "Missing $SNI_PATCH"
[[ -f "$NAIVE_BACKEND_INSTALL" ]] || die "Missing $NAIVE_BACKEND_INSTALL"

cat <<EOF
Unified real install plan
-------------------------
1. Run vendored x-ui-pro installer.
   Public nginx stream will own 0.0.0.0:443.
2. Patch /etc/nginx/stream-enabled/stream.conf:
   ${NAIVE_DOMAIN} -> ${NAIVE_BACKEND}
3. Install NaiveProxy/Caddy backend as caddy-naive:
   bind ${NAIVE_BACKEND}

WARNING:
The vendored x-ui-pro script is still destructive like upstream:
it removes existing x-ui and nginx configs and kills listeners on 80/443.
EOF

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in /etc/nginx /etc/x-ui /usr/local/x-ui /etc/caddy /etc/caddy-naive /etc/systemd/system/x-ui.service /etc/systemd/system/caddy-naive.service; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
ok "Backup directory: $backup_dir"

info "Running x-ui-pro installer"
bash "$XUI_SCRIPT" -install yes -panel 1 -subdomain "$XUI_DOMAIN" -reality_domain "$REALITY_DEST"

info "Adding nginx stream route for NaiveProxy"
bash "$SNI_PATCH" --naive-domain "$NAIVE_DOMAIN" --backend "$NAIVE_BACKEND"

info "Installing NaiveProxy backend"
bash "$NAIVE_BACKEND_INSTALL" --domain "$NAIVE_DOMAIN" --email "$NAIVE_EMAIL" --listen "$NAIVE_BACKEND"

ok "Unified install completed"
systemctl status x-ui --no-pager || true
systemctl status nginx --no-pager || true
systemctl status caddy-naive --no-pager || true
