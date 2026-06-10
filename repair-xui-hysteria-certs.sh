#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/xui-routing.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DOMAIN="${XUI_DOMAIN:-}"
ASSUME_YES=0
RESTART_XUI=1

usage() {
  cat <<EOF
Usage:
  sudo bash repair-xui-hysteria-certs.sh --domain gtgroundai.bot.nu --yes

Repairs 3x-ui/Xray startup failures caused by Hysteria2 inbounds pointing to
missing TLS files. If a Let's Encrypt certificate exists for --domain, the
script links it into /root/cert/<domain>/. Any still-broken Hysteria2 inbound
is disabled so it cannot prevent Xray core from starting.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --domain|--xui-domain) DOMAIN="${2:-}"; shift 2 ;;
    --no-restart) RESTART_XUI=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) upm_die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || upm_die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || upm_die "Add --yes after reading what this script changes"
[[ -f "$XUI_DB" ]] || upm_die "x-ui database not found: $XUI_DB"

backup_dir="/opt/unified-proxy-manager/backups/xui-hysteria-certs-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$XUI_DB" "$backup_dir/x-ui.db"
upm_log_ok "Backup directory: $backup_dir"

if [[ -n "$DOMAIN" ]]; then
  if xui_ensure_domain_cert_links "$DOMAIN"; then
    upm_log_ok "TLS certificate links are ready: /root/cert/$DOMAIN"
  else
    upm_log_warn "TLS certificate for $DOMAIN was not found under /root/cert or /etc/letsencrypt/live"
  fi
fi

XUI_DB="$XUI_DB" xui_disable_hysteria_inbounds_with_missing_certs

if [[ "$RESTART_XUI" == "1" ]] && command_exists systemctl; then
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || upm_die "x-ui failed to restart"
  XUI_DB="$XUI_DB" xui_wait_for_xray_core 10 || \
    upm_die "x-ui service is active but Xray core did not start. Run: journalctl -u x-ui -n 120 --no-pager -l"
fi

upm_log_ok "Hysteria2 certificate repair complete"
