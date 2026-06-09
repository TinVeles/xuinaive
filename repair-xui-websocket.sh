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
  sudo bash repair-xui-websocket.sh --domain x.example.com --yes

Repairs generated vless-ws inbounds for the 443 nginx path proxy:
  public wss://<domain>/<backend-port>/
  backend http://127.0.0.1:<backend-port>/<backend-port>/
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

backup_dir="/opt/unified-proxy-manager/backups/xui-ws-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$XUI_DB" "$backup_dir/x-ui.db"
for path in /etc/nginx/snippets/includes.conf /etc/nginx/nginx.conf; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
upm_log_ok "Backup directory: $backup_dir"

rows="$(sqlite3 -separator $'\t' "$XUI_DB" "
  SELECT id, port, COALESCE(remark,''), json(stream_settings)
  FROM inbounds
  WHERE protocol='vless'
    AND json_valid(stream_settings)=1
    AND json_extract(stream_settings,'$.network')='ws'
    AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
" 2>/dev/null || true)"

changed=0
while IFS=$'\t' read -r inbound_id inbound_port remark stream; do
  [[ "$inbound_id" =~ ^[0-9]+$ && "$inbound_port" =~ ^[0-9]+$ && -n "$stream" ]] || continue
  new_stream="$(jq -c --arg domain "$DOMAIN" --argjson port "$inbound_port" '
    .security = "none"
    | del(.tlsSettings)
    | .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"tls",dest:"",port:443,remark:""}] end)
    | .externalProxy[0].forceTls = "tls"
    | .externalProxy[0].dest = $domain
    | .externalProxy[0].port = 443
    | .externalProxy[0].remark = ""
    | .wsSettings = (.wsSettings // {})
    | .wsSettings.host = $domain
    | .wsSettings.path = ("/" + ($port|tostring) + "/")
    | .wsSettings.acceptProxyProtocol = false
    | .wsSettings.heartbeatPeriod = (.wsSettings.heartbeatPeriod // 0)
    | .wsSettings.headers = (.wsSettings.headers // {})
  ' <<<"$stream")"
  sqlite3 "$XUI_DB" "UPDATE inbounds SET stream_settings=$(sql_quote "$new_stream") WHERE id=$inbound_id;"
  changed=$((changed + 1))
  printf 'OK: repaired websocket inbound id=%s remark=%s public=wss://%s/%s/\n' "$inbound_id" "$remark" "$DOMAIN" "$inbound_port"
done <<<"$rows"

[[ "$changed" -gt 0 ]] || upm_die "No vless websocket inbounds found"

XUI_DB="$XUI_DB" XUI_PUBLIC_DOMAIN="$DOMAIN" xui_normalize_reference_preset_external_proxy_ports
XUI_DB="$XUI_DB" xui_ensure_nginx_dynamic_proxy

if command_exists nginx; then
  nginx -t
  systemctl reload nginx 2>/dev/null || true
fi

if [[ "$RESTART_XUI" == "1" ]] && command_exists systemctl; then
  systemctl restart x-ui
fi

upm_log_ok "WebSocket repair complete"
sqlite3 -readonly -column -header "$XUI_DB" "
  SELECT id, remark, port,
         json_extract(stream_settings,'$.externalProxy[0].dest') AS public_host,
         json_extract(stream_settings,'$.externalProxy[0].port') AS public_port,
         json_extract(stream_settings,'$.wsSettings.path') AS ws_path,
         json_extract(stream_settings,'$.security') AS backend_security
  FROM inbounds
  WHERE json_valid(stream_settings)=1
    AND json_extract(stream_settings,'$.network')='ws'
  ORDER BY id;
"
