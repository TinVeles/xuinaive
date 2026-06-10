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
  sudo bash repair-xui-public-domain.sh --domain x.example.com --yes

Repairs generated x-ui preset links so public client address/host is the x-ui
domain, not the subscription domain. Keeps subscription settings untouched.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|--xui-domain) DOMAIN="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --no-restart) RESTART_XUI=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) upm_die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || upm_die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || upm_die "Add --yes after reading what this script changes"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || upm_die "--domain is required"
[[ -f "$XUI_DB" ]] || upm_die "x-ui database not found: $XUI_DB"
for cmd in sqlite3 jq; do
  command_exists "$cmd" || upm_die "$cmd is required"
done

backup_dir="/opt/unified-proxy-manager/backups/xui-public-domain-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$XUI_DB" "$backup_dir/x-ui.db"
for path in \
  /etc/nginx/snippets/includes.conf \
  /etc/nginx/stream-enabled/stream.conf \
  /etc/nginx/stream-enabled/upm-xui-reality.conf; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
upm_log_ok "Backup directory: $backup_dir"

XUI_DB="$XUI_DB" xui_repair_invalid_inbound_json
XUI_DB="$XUI_DB" XUI_PUBLIC_DOMAIN="$DOMAIN" xui_normalize_reference_preset_external_proxy_ports
XUI_DB="$XUI_DB" xui_normalize_grpc_service_names
XUI_DB="$XUI_DB" xui_ensure_nginx_dynamic_proxy
XUI_DB="$XUI_DB" XUI_PUBLIC_DOMAIN="$DOMAIN" xui_ensure_nginx_xui_domain_route
XUI_DB="$XUI_DB" XUI_PUBLIC_DOMAIN="$DOMAIN" xui_ensure_nginx_reality_sni_routes
XUI_DB="$XUI_DB" xui_open_public_preset_ports

if command_exists nginx; then
  nginx -t
  systemctl reload nginx 2>/dev/null || true
fi

if [[ "$RESTART_XUI" == "1" ]] && command_exists systemctl; then
  systemctl restart x-ui
fi

upm_log_ok "x-ui public domain repair complete"
sqlite3 -readonly -column -header "$XUI_DB" "
  SELECT id, remark, protocol, port,
         json_extract(stream_settings,'$.network') AS net,
         json_extract(stream_settings,'$.security') AS sec,
         json_extract(stream_settings,'$.externalProxy[0].dest') AS public_host,
         json_extract(stream_settings,'$.externalProxy[0].port') AS public_port,
         COALESCE(json_extract(stream_settings,'$.wsSettings.path'),
                  json_extract(stream_settings,'$.xhttpSettings.path'),
                  json_extract(stream_settings,'$.grpcSettings.serviceName'),
                  '') AS path_or_service
  FROM inbounds
  WHERE enable=1
    AND json_valid(stream_settings)=1
    AND json_type(stream_settings,'$.externalProxy[0]')='object'
  ORDER BY id;
"
