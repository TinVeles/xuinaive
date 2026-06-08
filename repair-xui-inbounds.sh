#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DRY_RUN="${DRY_RUN:-0}"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
command_exists sqlite3 || die "sqlite3 is required"
command_exists jq || die "jq is required"
command_exists openssl || die "openssl is required"
[[ -f "$DB" ]] || die "x-ui database not found: $DB"

cat <<'EOF'
Unified Proxy Manager x-ui inbound repair
=========================================
This command repairs server-side x-ui presets, regenerates x-ui clients, and
runs the consolidated doctor report. It does not install WARP or RIXXX Panel.
EOF

if [[ "$DRY_RUN" == "1" ]]; then
  info "DRY_RUN=1: running REALITY diagnosis without database writes"
  DRY_RUN=1 XUI_DB="$DB" bash "$SCRIPT_DIR/fix-reality-connectivity.sh"
  exit 0
fi

backup_dir="/opt/unified-proxy-manager/backups/xui-repair-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$DB" "$backup_dir/x-ui.db"
ok "Backup directory: $backup_dir"

XUI_DB="$DB" xui_restore_reference_vless_grpc_reality_inbounds
if command_exists systemctl; then
  info "Restarting x-ui before REALITY diagnosis"
  systemctl restart x-ui
  sleep 2
fi

XUI_DB="$DB" bash "$SCRIPT_DIR/fix-reality-connectivity.sh"
bash "$SCRIPT_DIR/generate-profiles.sh" --xui-only --yes
bash "$SCRIPT_DIR/doctor.sh"

cat <<'EOF'

Client-side check for v2rayN
----------------------------
The server cannot change the Windows TUN inbound. Before testing REALITY delay:
  1. Disable TUN temporarily, or open Settings -> Option setting.
  2. Keep sniffing enabled if needed, but enable RouteOnly.
  3. Refresh the subscription and test again.

Without RouteOnly, v2rayN may replace the VPS address with the REALITY decoy
domain while testing. Example: vpn.example.com:11366 becomes ya.ru:11366.
EOF
