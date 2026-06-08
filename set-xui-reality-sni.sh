#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/xui-routing.sh"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
REALITY_DOMAIN=""
TARGET="${REALITY_TARGET:-127.0.0.1:9443}"
ASSUME_YES=0

usage() {
  cat <<EOF
Usage:
  sudo bash set-xui-reality-sni.sh --domain REALITY_DOMAIN --yes

What it does:
  - changes all enabled non-WARP REALITY inbounds to use REALITY_DOMAIN as serverNames[0]
  - sets REALITY target to ${TARGET}
  - ensures nginx stream routes REALITY_DOMAIN to xray
  - restarts x-ui and reloads nginx

Notes:
  REALITY_DOMAIN must be different from x-ui, RIXXX/Naive, and subscription domains.
  If target is local 127.0.0.1:9443, nginx must have a TLS server for REALITY_DOMAIN there.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) REALITY_DOMAIN="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ -n "$REALITY_DOMAIN" ]] || die "--domain is required"
[[ "$REALITY_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "Invalid domain: $REALITY_DOMAIN"
[[ -f "$XUI_DB" ]] || die "x-ui database not found: $XUI_DB"
command_exists sqlite3 || die "sqlite3 is required"
command_exists jq || die "jq is required"

backup_dir="/opt/unified-proxy-manager/backups/reality-sni-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$XUI_DB" /etc/nginx/stream-enabled/stream.conf; do
  [[ -e "$path" || -L "$path" ]] || continue
  mkdir -p "$backup_dir$(dirname "$path")"
  cp -a "$path" "$backup_dir$(dirname "$path")/"
done

updated="$(sqlite3 "$XUI_DB" "
  UPDATE inbounds
  SET stream_settings = json_set(
    stream_settings,
    '$.realitySettings.serverNames',
    json_array($(sql_quote "$REALITY_DOMAIN")),
    '$.realitySettings.target',
    $(sql_quote "$TARGET")
  )
  WHERE protocol='vless'
    AND json_valid(stream_settings)=1
    AND json_extract(stream_settings,'$.network')='tcp'
    AND json_extract(stream_settings,'$.security')='reality'
    AND COALESCE(tag,'') NOT LIKE '%-warp'
    AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
  SELECT changes();
")"
updated="${updated##*$'\n'}"
[[ "$updated" =~ ^[0-9]+$ && "$updated" -gt 0 ]] || die "No non-WARP REALITY inbounds were updated"

xui_ensure_nginx_reality_sni_routes

if command_exists nginx; then
  nginx -t || die "nginx validation failed"
  systemctl reload nginx 2>/dev/null || true
fi
systemctl restart x-ui 2>/dev/null || true

ok "Reality SNI changed to $REALITY_DOMAIN on $updated inbound(s)"
ok "Backup: $backup_dir"
