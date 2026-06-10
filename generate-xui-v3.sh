#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/warp.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/xui-routing.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/xui-v3.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
COUNT="${COUNT:-15}"
PREFIX="${PREFIX:-auto}"
DOMAIN="${XUI_DOMAIN:-}"
XUI_EMOJI_FLAG="${XUI_EMOJI_FLAG:-🇫🇮}"
REALITY_DEST="${REALITY_DEST:-}"
RESET_INBOUNDS=0
RESTART_XUI=1
ASSUME_YES=0
XUI_CREATE_WARP_PRESETS="${XUI_CREATE_WARP_PRESETS:-0}"
HY2_WARP_PUBLIC_PORT="${HY2_WARP_PUBLIC_PORT:-24443}"
XUI_PRESET_PROFILE="${XUI_PRESET_PROFILE:-stable}"

usage() {
  cat <<EOF
Usage:
  sudo bash generate-xui-v3.sh --count 15 --prefix auto --yes
  sudo bash generate-xui-v3.sh --reset-inbounds --domain x.example.com --reality-dest r.example.com --yes
  sudo bash generate-xui-v3.sh --reset-inbounds --extended-presets --domain x.example.com --reality-dest r.example.com --yes
  sudo bash generate-xui-v3.sh --xui-warp-presets --hy2-warp-port 24443 --yes

Creates one v3 client entity per profile and attaches it to every generated
compatible inbound through client_inbounds. This script is only for 3x-ui v3.

Default reset preset profile is stable x-ui-pro-like core:
  vless tcp reality, vless ws, vless xhttp, trojan grpc.
Use --extended-presets only when you explicitly want the larger experimental
mix with extra REALITY decoys, Shadowsocks, Hysteria2, and Trojan TCP REALITY.

--xui-warp-presets creates enabled manual WARP prep inbounds:
  vless tcp reality, vless xhttp reality, hysteria2 udp.
It does not create WARP outbound or routing rules.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --count) COUNT="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --domain|--xui-domain) DOMAIN="${2:-}"; shift 2 ;;
    --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
    --reset-inbounds) RESET_INBOUNDS=1; shift ;;
    --preset-profile) XUI_PRESET_PROFILE="${2:-}"; shift 2 ;;
    --stable-core|--stable-presets) XUI_PRESET_PROFILE="stable"; shift ;;
    --extended-presets) XUI_PRESET_PROFILE="extended"; shift ;;
    --xui-warp-presets) XUI_CREATE_WARP_PRESETS=1; shift ;;
    --no-xui-warp-presets) XUI_CREATE_WARP_PRESETS=0; shift ;;
    --hy2-warp-port) HY2_WARP_PUBLIC_PORT="${2:-}"; shift 2 ;;
    --warp-reality-decoy) REALITY_WARP_TCP_DECOY="${2:-}"; shift 2 ;;
    --warp-xhttp-decoy) REALITY_WARP_XHTTP_DECOY="${2:-}"; shift 2 ;;
    --no-restart) RESTART_XUI=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) upm_die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || upm_die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || upm_die "Add --yes after reading what this script changes"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || upm_die "--count must be a positive number"
[[ "$PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || upm_die "--prefix may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
[[ "$XUI_PRESET_PROFILE" == "stable" || "$XUI_PRESET_PROFILE" == "extended" ]] || upm_die "--preset-profile must be stable or extended"
[[ "$HY2_WARP_PUBLIC_PORT" =~ ^[0-9]+$ && "$HY2_WARP_PUBLIC_PORT" -gt 0 && "$HY2_WARP_PUBLIC_PORT" -le 65535 ]] || upm_die "--hy2-warp-port must be 1..65535"
for cmd in sqlite3 jq openssl; do
  command_exists "$cmd" || upm_die "$cmd is required"
done
for function_name in xui_repair_invalid_inbound_json xui_sanitize_inbound_tags; do
  declare -F "$function_name" >/dev/null || \
    upm_die "Shared x-ui helper is missing: $function_name. Pull a complete repository update."
done
if [[ "$RESET_INBOUNDS" == "1" ]]; then
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || upm_die "--domain is required with --reset-inbounds"
  [[ "$REALITY_DEST" =~ ^[A-Za-z0-9.-]+$ ]] || upm_die "--reality-dest is required with --reset-inbounds"
fi

xui_v3_require_schema "$XUI_DB"
backup_dir="/opt/unified-proxy-manager/backups/xui-v3-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$XUI_DB" "$backup_dir/x-ui.db"
for path in /etc/nginx/snippets/includes.conf /etc/nginx/stream-enabled/stream.conf /etc/nginx/stream-enabled/upm-xui-reality.conf; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
upm_log_ok "Backup directory: $backup_dir"

xui_was_active=0
restart_xui_after_failure() {
  local status=$?
  if [[ "$status" -ne 0 && "$xui_was_active" == "1" ]]; then
    upm_log_warn "Profile generation failed; restarting the previously active x-ui service"
    systemctl restart x-ui >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap restart_xui_after_failure EXIT

if command_exists systemctl && systemctl is-active --quiet x-ui; then
  xui_was_active=1
  systemctl stop x-ui
fi

if [[ "$RESET_INBOUNDS" == "1" ]]; then
  sqlite3 "$XUI_DB" "DELETE FROM client_inbounds; DELETE FROM client_traffics; DELETE FROM clients;"
  xray_binary="$(xui_v3_xray_binary || true)"
  [[ -n "$xray_binary" ]] || upm_die "Could not find the installed Xray binary"
  output="$("$xray_binary" x25519)"
  private_key="$(awk -F': *' 'tolower($1) ~ /^private[ _-]?key$/ {print $2; exit}' <<<"$output")"
  public_key="$(awk -F': *' 'tolower($1) ~ /^public[ _-]?key$/ || tolower($1) ~ /publickey/ {print $2; exit}' <<<"$output")"
  [[ -n "$private_key" && -n "$public_key" ]] || upm_die "Could not parse xray x25519 key pair"
  XUI_DB="$XUI_DB" XUI_PRESET_PROFILE="$XUI_PRESET_PROFILE" REALITY_DEST="$REALITY_DEST" xui_install_3dp_reference_presets \
    "$XUI_DB" "$DOMAIN" "$private_key" "$public_key" "$XUI_EMOJI_FLAG" \
    "/root/cert/${DOMAIN}/fullchain.pem" "/root/cert/${DOMAIN}/privkey.pem"
fi

XUI_DB="$XUI_DB" xui_repair_invalid_inbound_json
XUI_DB="$XUI_DB" xui_remove_deprecated_vmess_presets
XUI_DB="$XUI_DB" xui_disable_experimental_trojan_grpc_presets
XUI_DB="$XUI_DB" xui_sanitize_inbound_tags
XUI_DB="$XUI_DB" xui_normalize_xhttp_tcp_inbounds
XUI_DB="$XUI_DB" xui_normalize_grpc_service_names
XUI_DB="$XUI_DB" xui_restore_reference_vless_grpc_reality_inbounds
XUI_DB="$XUI_DB" XUI_PUBLIC_DOMAIN="$DOMAIN" xui_normalize_reference_preset_external_proxy_ports
XUI_DB="$XUI_DB" xui_enable_preset_domain_sniffing
upm_sqlite_setting_set "$XUI_DB" "subEmailInRemark" "false"

report_file="/etc/x-ui/generated-clients-v3.txt"
mkdir -p "$(dirname "$report_file")"
XUI_DB="$XUI_DB" \
XUI_CREATE_WARP_PRESETS="$XUI_CREATE_WARP_PRESETS" \
HY2_WARP_PUBLIC_PORT="$HY2_WARP_PUBLIC_PORT" \
XUI_EMOJI_FLAG="$XUI_EMOJI_FLAG" \
REALITY_WARP_TCP_DECOY="${REALITY_WARP_TCP_DECOY:-}" \
REALITY_WARP_XHTTP_DECOY="${REALITY_WARP_XHTTP_DECOY:-}" \
  xui_ensure_v3_manual_warp_presets "$XUI_DB" "$DOMAIN" "$report_file"
XUI_DB="$XUI_DB" XUI_EMOJI_FLAG="$XUI_EMOJI_FLAG" xui_normalize_reference_preset_remarks
XUI_DB="$XUI_DB" \
XUI_V3_INCLUDE_WARP_PRESETS="$XUI_CREATE_WARP_PRESETS" \
  xui_v3_replace_generated_clients "$XUI_DB" "$COUNT" "$PREFIX" "$report_file"

XUI_DB="$XUI_DB" xui_ensure_nginx_dynamic_proxy
XUI_DB="$XUI_DB" XUI_CREATE_WARP_PRESETS="$XUI_CREATE_WARP_PRESETS" xui_ensure_nginx_reality_sni_routes
XUI_DB="$XUI_DB" xui_open_public_preset_ports

if [[ "$RESTART_XUI" == "1" ]] && command_exists systemctl; then
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || upm_die "x-ui failed to restart"
  xui_wait_for_xray_core 10 || \
    upm_die "x-ui service is active but Xray core did not start. Run: journalctl -u x-ui -n 120 --no-pager -l"
fi

upm_log_ok "3x-ui v3 clients generated: $COUNT client entities attached to every preset inbound"
upm_log_ok "x-ui preset profile: $XUI_PRESET_PROFILE"
if [[ "$XUI_CREATE_WARP_PRESETS" == "1" ]]; then
  upm_log_ok "Manual WARP prep inbounds: vless reality, vless xhttp, hysteria2"
fi
upm_log_ok "Report: $report_file"
