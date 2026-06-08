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
source "$LIB_DIR/warp.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/xui-routing.sh"

COUNT="${COUNT:-15}"
PREFIX="${PREFIX:-auto}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
NH_CONFIG="${NH_CONFIG:-/etc/rixxx-panel/config.json}"
CADDYFILE="${CADDYFILE:-/etc/caddy-naive/Caddyfile}"
NH_PROFILE_MAP="${NH_PROFILE_MAP:-/etc/rixxx-panel/generated-profile-map.json}"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-generated}"
WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}"
XUI_APPLY_WARP_TEMPLATE="${XUI_APPLY_WARP_TEMPLATE:-0}"
XUI_INBOUND_ID="${XUI_INBOUND_ID:-}"
XUI_COMMON_SUB_ID="${XUI_COMMON_SUB_ID:-$PREFIX}"
XUI_SUB_ID_MODE="${XUI_SUB_ID_MODE:-per-client}"
XUI_CREATE_DIRECT="${XUI_CREATE_DIRECT:-1}"
XUI_CREATE_WARP_INBOUNDS="${XUI_CREATE_WARP_INBOUNDS:-0}"
XUI_WARP_INBOUNDS_ENABLE="${XUI_WARP_INBOUNDS_ENABLE:-0}"
XUI_ENABLE_WARP_ROUTING="${XUI_ENABLE_WARP_ROUTING:-0}"
XUI_CLEANUP_WARP_TEMPLATE="${XUI_CLEANUP_WARP_TEMPLATE:-0}"
XUI_AUTO_INSTALL_WARP="${XUI_AUTO_INSTALL_WARP:-0}"
XUI_REPLACE_CLIENTS="${XUI_REPLACE_CLIENTS:-1}"
CREATE_XUI="${CREATE_XUI:-1}"
CREATE_NH="${CREATE_NH:-0}"
COMBINED_ONLY="${COMBINED_ONLY:-0}"
RELOAD_SERVICES="${RELOAD_SERVICES:-1}"
ASSUME_YES=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { printf '%s\n' "${BLUE}INFO:${NC} $*"; }
ok() { printf '%s\n' "${GREEN}OK:${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${NC} $*"; }
err() { printf '%s\n' "${RED}ERROR:${NC} $*" >&2; }
die() { err "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_node_runtime() {
  command_exists node && return 0
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command_exists apt-get; then
    info "Installing Node.js runtime required for subscription generation"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  command_exists node || die "node is required. Install it with: sudo apt-get update && sudo apt-get install -y nodejs"
}

usage() {
  cat <<EOF
Usage:
  sudo bash generate-profiles.sh --yes
  sudo bash generate-profiles.sh --count 15 --prefix auto --yes
  sudo bash generate-profiles.sh --xui-only --yes
  sudo bash generate-profiles.sh --install-warp --yes

Creates:
  x-ui:  COUNT standard clients on every selected preset inbound.
         Default subscriptions: one subId per client index.
  RIXXX: NaiveProxy and Mieru users are managed in RIXXX Panel.

  WARP routing:
  outbound tag: ${WARP_OUTBOUND_TAG}
  local proxy:  ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
  inbound filter: ${WARP_INBOUND_TAG} (all = no inboundTag in routing rule)
  AI domains:   ${WARP_AI_DOMAINS}
  disabled by default; enable routing manually with --xui-warp-routing.
  WARP mirror inbounds are disabled by default. Add --xui-warp-inbounds only for advanced mirror profiles.
  AI-domain WARP routing is written to /etc/x-ui/warp-generated-routing.json when enabled.
  auto-installs Cloudflare WARP local proxy only with --install-warp or --auto-install-warp.
  use --apply-xui-warp-template to also write warp-cli outbound/rules into x-ui settings.
  use --cleanup-xui-warp-template to remove previously written warp-cli outbound/rules.

x-ui selection:
  default: every preset vless/trojan inbound
  --xui-inbound-id ID: only one inbound
  default subId mode: per-client (PREFIX-01 contains all protocol variants for PREFIX-01)
  --xui-sub-id-mode common: one subscription contains all generated clients
  default replace mode: selected inbound clients become exactly COUNT
  --xui-keep-existing: keep existing non-generated clients
  --no-xui-warp-inbounds: do not create/use WARP mirror inbounds
  --xui-enable-warp-inbounds: create WARP mirror inbounds enabled (advanced; requires working public ingress)
  --combined-only: removed; use x-ui subscriptions and RIXXX Panel separately
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --rixxx-config) NH_CONFIG="${2:-}"; shift 2 ;;
    --caddyfile) CADDYFILE="${2:-}"; shift 2 ;;
    --hysteria-config) die "--hysteria-config was removed; RIXXX Panel manages Mieru" ;;
    --subscription-dir) die "--subscription-dir was removed; RIXXX Panel manages NaiveProxy/Mieru links" ;;
    --no-nginx-subscription) shift ;;
    --warp-host) WARP_PROXY_HOST="${2:-}"; shift 2 ;;
    --warp-port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --warp-outbound-tag) WARP_OUTBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-inbound-tag) WARP_INBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-ai-domains) WARP_AI_DOMAINS="${2:-}"; shift 2 ;;
    --xui-inbound-id) XUI_INBOUND_ID="${2:-}"; shift 2 ;;
    --xui-common-sub-id) XUI_COMMON_SUB_ID="${2:-}"; shift 2 ;;
    --xui-sub-id-mode) XUI_SUB_ID_MODE="${2:-}"; shift 2 ;;
    --install-warp) XUI_ENABLE_WARP_ROUTING=1; XUI_AUTO_INSTALL_WARP=1; shift ;;
    --xui-warp-routing) XUI_ENABLE_WARP_ROUTING=1; shift ;;
    --no-xui-warp-routing) XUI_ENABLE_WARP_ROUTING=0; shift ;;
    --apply-xui-warp-template) XUI_APPLY_WARP_TEMPLATE=1; shift ;;
    --no-apply-xui-warp-template) XUI_APPLY_WARP_TEMPLATE=0; shift ;;
    --cleanup-xui-warp-template) XUI_CLEANUP_WARP_TEMPLATE=1; shift ;;
    --no-auto-install-warp) XUI_AUTO_INSTALL_WARP=0; shift ;;
    --auto-install-warp) XUI_AUTO_INSTALL_WARP=1; shift ;;
    --xui-direct-clients) XUI_CREATE_DIRECT=1; shift ;;
    --no-xui-direct-clients) XUI_CREATE_DIRECT=0; shift ;;
    --xui-warp-inbounds) XUI_CREATE_WARP_INBOUNDS=1; shift ;;
    --no-xui-warp-inbounds) XUI_CREATE_WARP_INBOUNDS=0; shift ;;
    --xui-enable-warp-inbounds) XUI_WARP_INBOUNDS_ENABLE=1; shift ;;
    --xui-disable-warp-inbounds) XUI_WARP_INBOUNDS_ENABLE=0; shift ;;
    --xui-keep-existing) XUI_REPLACE_CLIENTS=0; shift ;;
    --xui-only) CREATE_XUI=1; CREATE_NH=0; shift ;;
    --combined-only) die "--combined-only was removed; use x-ui subscriptions and RIXXX Panel separately" ;;
    --no-reload) RELOAD_SERVICES=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || die "--count must be a positive number"
[[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--warp-port must be numeric"
[[ "$PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--prefix may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
[[ -z "$XUI_INBOUND_ID" || "$XUI_INBOUND_ID" =~ ^[0-9]+$ ]] || die "--xui-inbound-id must be numeric"
[[ "$XUI_COMMON_SUB_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--xui-common-sub-id may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
[[ "$XUI_SUB_ID_MODE" == "per-client" || "$XUI_SUB_ID_MODE" == "common" ]] || die "--xui-sub-id-mode must be per-client or common"
[[ "$XUI_CREATE_WARP_INBOUNDS" == "0" || "$XUI_CREATE_WARP_INBOUNDS" == "1" ]] || die "XUI_CREATE_WARP_INBOUNDS must be 0 or 1"
[[ "$XUI_WARP_INBOUNDS_ENABLE" == "0" || "$XUI_WARP_INBOUNDS_ENABLE" == "1" ]] || die "XUI_WARP_INBOUNDS_ENABLE must be 0 or 1"
if [[ "$XUI_CREATE_DIRECT" != "1" ]]; then
  warn "Standard clients are disabled; enabling them because clone inbounds are no longer supported."
  XUI_CREATE_DIRECT=1
fi

ensure_node_runtime
for cmd in openssl; do
  command_exists "$cmd" || die "$cmd is required"
done
if [[ "$CREATE_XUI" == "1" || "$COMBINED_ONLY" == "1" ]]; then
  command_exists sqlite3 || die "sqlite3 is required for x-ui profile generation"
  [[ -f "$XUI_DB" ]] || die "x-ui database not found: $XUI_DB"
fi
if [[ "$CREATE_XUI" == "1" ]]; then
  command_exists jq || die "jq is required for x-ui profile generation"
fi
if [[ "$CREATE_XUI" == "1" && "$XUI_ENABLE_WARP_ROUTING" == "1" && "$XUI_AUTO_INSTALL_WARP" == "1" ]]; then
  ensure_warp_local_proxy "$SCRIPT_DIR"
fi

backup_dir="/opt/unified-proxy-manager/backups/profiles-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$XUI_DB" "$NH_CONFIG" "$CADDYFILE" "$NH_PROFILE_MAP" /etc/nginx/snippets/includes.conf /etc/nginx/stream-enabled/stream.conf /etc/nginx/stream-enabled/upm-xui-reality.conf; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
ok "Backup directory: $backup_dir"

rand_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20
}

uuid_value() {
  if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
    /usr/local/x-ui/bin/xray-linux-amd64 uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

xui_next_free_port() {
  local candidate="$1"
  [[ "$candidate" =~ ^[0-9]+$ && "$candidate" -gt 0 ]] || { printf '0\n'; return 0; }
  while [[ "$(sqlite3 -readonly "$XUI_DB" "SELECT COUNT(*) FROM inbounds WHERE port=$candidate;" 2>/dev/null || echo 0)" != "0" ]]; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

xui_profile_label() {
  local inbound_id="$1" protocol="$2" stream_settings network security
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "xui_profile_label: invalid inbound_id: $inbound_id"
  stream_settings="$(sqlite3 -readonly "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
  network="$(jq -r '.network // "tcp"' <<<"$stream_settings" 2>/dev/null || echo "tcp")"
  security="$(jq -r '.security // "none"' <<<"$stream_settings" 2>/dev/null || echo "none")"
  if [[ "$security" == "reality" ]]; then
    printf '%s-reality-%s\n' "$network" "$inbound_id"
  elif [[ "$protocol" == "hysteria" || "$protocol" == "hysteria2" ]]; then
    printf 'hy2-%s\n' "$inbound_id"
  elif [[ "$protocol" == "trojan" && "$network" == "grpc" ]]; then
    printf 'trojan-grpc\n'
  elif [[ -n "$network" && "$network" != "null" ]]; then
    printf '%s-%s-%s\n' "$protocol" "$network" "$inbound_id" | tr -cd 'A-Za-z0-9_.-'
  else
    printf 'inbound-%s\n' "$inbound_id"
  fi
}

profile_indices() {
  local total="$1" width i
  width="${#total}"
  [[ "$width" -lt 2 ]] && width=2
  for ((i = 1; i <= total; i++)); do
    printf "%0${width}d\n" "$i"
  done
}

xui_reality_client_base() {
  xui_generated_client_base "$1"
}

xui_client_email() {
  local index="$1" mode="$2" label="$3" base="${4:-}"
  [[ -n "$base" ]] || base="${PREFIX}-${index}"
  if [[ "$mode" == "direct" || "$mode" == "standard" ]]; then
    printf '%s-%s\n' "$label" "$base"
  else
    printf '%s-%s-%s\n' "$mode" "$label" "$base"
  fi
}

xui_client_json() {
  local inbound_id="$1" protocol="$2" email="$3" sub_id="$4" now="$5" existing_json="${6:-{}}" password uid client_json is_reality network
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "xui_client_json: invalid inbound_id: $inbound_id"
  if [[ -z "$existing_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$existing_json"; then
    existing_json="{}"
  fi
  is_reality=0
  if sqlite3 "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" | grep -q '"security"[[:space:]]*:[[:space:]]*"reality"'; then
    is_reality=1
  fi
  network="$(sqlite3 -readonly "$XUI_DB" "SELECT COALESCE(json_extract(stream_settings,'$.network'),'tcp') FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || printf 'tcp')"
  if [[ "$protocol" == "trojan" ]]; then
    password="$(rand_password)"
    jq -cn \
      --arg email "$email" \
      --arg subId "$sub_id" \
      --arg password "$password" \
      --arg now "$now" \
      --argjson old "$existing_json" \
      '($old // {}) as $o
      | ($o.password // $o.id // $password) as $p
      | {
          comment:($o.comment // ""),
          created_at:($o.created_at // ($now|tonumber)),
          email:$email,
          enable:($o.enable // true),
          expiryTime:($o.expiryTime // 0),
          limitIp:($o.limitIp // 0),
          password:$p,
          id:$p,
          reset:($o.reset // 0),
          subId:$subId,
          tgId:($o.tgId // 0),
          totalGB:($o.totalGB // 0),
          updated_at:($o.updated_at // ($now|tonumber))
        }'
  elif [[ "$protocol" == "shadowsocks" ]]; then
    password="$(openssl rand -base64 32 | tr -d '\n')"
    jq -cn \
      --arg email "$email" \
      --arg subId "$sub_id" \
      --arg password "$password" \
      --argjson old "$existing_json" \
      '($old // {}) as $o
      | {
          id:"",
          flow:"",
          email:$email,
          password:($o.password // $password),
          enable:($o.enable // true),
          limitIp:($o.limitIp // 0),
          totalGB:($o.totalGB // 0),
          expiryTime:($o.expiryTime // 0),
          tgId:($o.tgId // ""),
          subId:$subId,
          reset:($o.reset // 0)
        }'
  elif [[ "$protocol" == "hysteria" || "$protocol" == "hysteria2" ]]; then
    password="$(rand_password)"
    jq -cn \
      --arg email "$email" \
      --arg subId "$sub_id" \
      --arg auth "$password" \
      --argjson old "$existing_json" \
      '($old // {}) as $o
      | {auth:($o.auth // $auth),email:$email,enable:($o.enable // true),subId:$subId}'
  else
    uid="$(uuid_value | tr -d '[:space:]')"
    client_json="$(jq -cn \
      --arg email "$email" \
      --arg subId "$sub_id" \
      --arg id "$uid" \
      --arg now "$now" \
      --argjson old "$existing_json" \
      '($old // {}) as $o
      | {
          id:($o.id // $id),
          flow:($o.flow // ""),
          email:$email,
          limitIp:($o.limitIp // 0),
          totalGB:($o.totalGB // 0),
          expiryTime:($o.expiryTime // 0),
          enable:($o.enable // true),
          tgId:($o.tgId // ""),
          subId:$subId,
          reset:($o.reset // 0),
          comment:($o.comment // ""),
          created_at:($o.created_at // ($now|tonumber)),
          updated_at:($o.updated_at // ($now|tonumber))
        }')"
    if [[ "$is_reality" == "1" && "$network" == "tcp" ]]; then
      jq '.flow = "xtls-rprx-vision"' <<<"$client_json"
    else
      printf '%s\n' "$client_json"
    fi
  fi
}

xui_normalize_inbound_settings() {
  local protocol="$1"
  if [[ "$protocol" == "vless" ]]; then
    jq -c '.decryption = "none"'
  else
    jq -c '.'
  fi
}

xui_enable_standard_preset_inbounds() {
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET enable=1
    WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql);
  "
}

xui_replace_generated_clients() {
  local inbound_id="$1" protocol="$2" mode="$3" tag="$4" report_file="$5"
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "xui_replace_generated_clients: invalid inbound_id: $inbound_id"
  local now index label email sub_id base client_json clients_json settings new_settings traffic_result existing_json first_auth
  now="$(date +%s)000"
  clients_json="[]"
  label="$(xui_profile_label "$inbound_id" "$protocol")"
  settings="$(sqlite3 -readonly "$XUI_DB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"

  for index in $(profile_indices "$COUNT"); do
    sub_id="${PREFIX}-${index}"
    if [[ "$XUI_SUB_ID_MODE" == "common" ]]; then
      sub_id="$XUI_COMMON_SUB_ID"
    fi
    base="$(xui_reality_client_base "$sub_id")"
    email="$(xui_client_email "$index" "$mode" "$label" "$base")"
    existing_json="$(xui_existing_generated_client_json "$settings" "$email" "$sub_id" "$XUI_SUB_ID_MODE")"
    client_json="$(xui_client_json "$inbound_id" "$protocol" "$email" "$sub_id" "$now" "$existing_json")"
    if [[ -z "$client_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$client_json"; then
      die "Invalid generated client JSON for inbound=$inbound_id email=$email"
    fi
    clients_json="$(jq -c --argjson client "$client_json" '. + [$client]' <<<"$clients_json")"
  done

  if [[ "$XUI_REPLACE_CLIENTS" == "1" ]]; then
    new_settings="$(jq -c --argjson clients "$clients_json" '.clients = $clients' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  else
    new_settings="$(jq -c --arg prefix "$PREFIX" --argjson clients "$clients_json" '
      def generated_client:
        ((.email // "") | tostring) as $email
        | ((.subId // "") | tostring) as $sub
        | ($sub | startswith($prefix + "-"))
          or ($email | startswith($prefix + "-"))
          or ($email | contains("-" + $prefix + "-"));
      .clients = ((.clients // [])
        | map(select(generated_client | not))
        + $clients)
    ' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  fi

  sqlite3 "$XUI_DB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  if [[ "$protocol" == "hysteria" || "$protocol" == "hysteria2" ]]; then
    first_auth="$(jq -r '(.clients // [])[0].auth // ""' <<<"$new_settings")"
    [[ -n "$first_auth" ]] && sqlite3 "$XUI_DB" "
      UPDATE inbounds
      SET stream_settings=json_set(stream_settings, '$.hysteriaSettings.auth', $(sql_quote "$first_auth"))
      WHERE id=$inbound_id AND json_valid(stream_settings)=1;
    "
  fi
  if [[ "$XUI_REPLACE_CLIENTS" == "1" ]]; then
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id;"
  else
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "${PREFIX}-[0-9]*");"
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "*-${PREFIX}-[0-9]*");"
  fi
  for index in $(profile_indices "$COUNT"); do
    if [[ "$XUI_SUB_ID_MODE" == "common" ]]; then
      sub_id="$XUI_COMMON_SUB_ID"
    else
      sub_id="${PREFIX}-${index}"
    fi
    base="$(xui_reality_client_base "$sub_id")"
    email="$(xui_client_email "$index" "$mode" "$label" "$base")"
    traffic_result="$(sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, 1, $(sql_quote "$email"), 0, 0, 0, 0, 0); SELECT changes();" 2>/dev/null || true)"
    if [[ "${traffic_result##*$'\n'}" != "1" ]]; then
      printf 'WARN traffic duplicate/ignored inbound=%s email=%s\n' "$inbound_id" "$email" >> "$report_file"
    fi
    printf 'inbound=%s protocol=%s tag=%s mode=%s email=%s subId=%s\n' "$inbound_id" "$protocol" "${tag:-}" "$mode" "$email" "$sub_id" >> "$report_file"
  done
}

xui_prune_generated_clients() {
  local inbound_id="$1" protocol="$2" report_file="$3" settings new_settings
  [[ "$inbound_id" =~ ^[0-9]+$ ]] || die "xui_prune_generated_clients: invalid inbound_id: $inbound_id"
  settings="$(sqlite3 -readonly "$XUI_DB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  new_settings="$(jq -c --arg prefix "$PREFIX" '
    def generated_client:
      ((.email // "") | tostring) as $email
      | ((.subId // "") | tostring) as $sub
      | ($sub | startswith($prefix + "-"))
        or ($email | startswith($prefix + "-"))
        or ($email | contains("-" + $prefix + "-"));
    .clients = ((.clients // []) | map(select(generated_client | not)))
  ' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  sqlite3 "$XUI_DB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "${PREFIX}-[0-9]*");"
  sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "*-${PREFIX}-[0-9]*");"
  printf 'inbound=%s mode=direct action=pruned-generated prefix=%s\n' "$inbound_id" "$PREFIX" >> "$report_file"
}

xui_add_clients() {
  info "Creating x-ui clients in $XUI_DB"
  local inbound_rows inbound_id protocol tag remark port enable report_file warp_tags_file query mirror_row mirror_id mirror_protocol mirror_tag routing_tag
  report_file="/etc/x-ui/generated-clients.txt"
  warp_tags_file="$(mktemp)"
  mkdir -p "$(dirname "$report_file")"
  : > "$report_file"
  xui_repair_invalid_inbound_json
  xui_clear_trojan_client_flows
  xui_repair_shadowsocks_2022_keys
  xui_remove_deprecated_vmess_presets
  xui_disable_experimental_trojan_grpc_presets
  xui_sanitize_inbound_tags
  xui_disable_nginx_enabled_backup_configs
  xui_enable_standard_preset_inbounds
  xui_normalize_xhttp_tcp_inbounds
  xui_normalize_grpc_service_names
  xui_restore_reference_vless_grpc_reality_inbounds
  xui_normalize_reference_preset_external_proxy_ports
  xui_ensure_nginx_dynamic_proxy
  xui_ensure_nginx_reality_sni_routes
  xui_enable_preset_domain_sniffing
  xui_ensure_warp_mirror_inbounds "$report_file"
  xui_open_warp_reality_ports
  xui_open_public_preset_ports

  query="SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), port, enable
     FROM inbounds
     WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
       AND COALESCE(tag,'') NOT LIKE '%-warp'
       AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql)"
  if [[ -n "$XUI_INBOUND_ID" ]]; then
    query="$query AND id=$XUI_INBOUND_ID"
  fi
  query="$query ORDER BY id;"
  inbound_rows="$(sqlite3 -separator $'\t' "$XUI_DB" "$query")"
  [[ -n "$inbound_rows" ]] || die "No x-ui preset inbounds found in $XUI_DB"

  while IFS=$'\t' read -r inbound_id protocol tag remark port enable; do
    [[ -n "$inbound_id" ]] || continue

    if [[ "$XUI_CREATE_DIRECT" == "1" ]]; then
      xui_replace_generated_clients "$inbound_id" "$protocol" "direct" "$tag" "$report_file"
      routing_tag="$tag"
      if [[ "$XUI_CREATE_WARP_INBOUNDS" == "1" && -n "$tag" ]]; then
        mirror_row="$(sqlite3 -separator $'\t' "$XUI_DB" "SELECT id, protocol, COALESCE(tag,'') FROM inbounds WHERE tag=$(sql_quote "${tag}-warp") LIMIT 1;" 2>/dev/null || true)"
        if [[ -n "$mirror_row" ]]; then
          IFS=$'\t' read -r mirror_id mirror_protocol mirror_tag <<<"$mirror_row"
          xui_replace_generated_clients "$mirror_id" "$mirror_protocol" "warp" "$mirror_tag" "$report_file"
          if [[ "${XUI_WARP_INBOUNDS_ENABLE:-0}" == "1" ]]; then
            routing_tag="$mirror_tag"
          fi
          ok "x-ui WARP mirror inbound ${mirror_id}: $COUNT clients, subId mode=$XUI_SUB_ID_MODE"
        fi
      fi
      [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && -n "$routing_tag" ]] && printf '%s\n' "$routing_tag" >> "$warp_tags_file"
    else
      xui_prune_generated_clients "$inbound_id" "$protocol" "$report_file"
    fi
    ok "x-ui inbound ${inbound_id}: $COUNT clients, subId mode=$XUI_SUB_ID_MODE"
  done <<<"$inbound_rows"

  if [[ "$XUI_CLEANUP_WARP_TEMPLATE" == "1" ]]; then
    xui_remove_warp_template
  elif [[ "$XUI_ENABLE_WARP_ROUTING" == "1" ]]; then
    xui_apply_warp_template "$warp_tags_file"
  elif [[ "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    xui_remove_warp_template
  fi
  rm -f "$warp_tags_file"
}

xui_cleanup_unix_sockets() {
  [[ -f "$XUI_DB" ]] || return 0
  sqlite3 -readonly "$XUI_DB" "SELECT listen FROM inbounds WHERE listen LIKE '/%';" 2>/dev/null \
    | while IFS= read -r listen_path; do
        [[ -n "$listen_path" ]] || continue
        socket_path="${listen_path%%,*}"
        [[ "$socket_path" == /dev/shm/* || "$socket_path" == /run/* || "$socket_path" == /tmp/* ]] || continue
        rm -f -- "$socket_path" || true
      done
}

xui_install_uds_cleanup_dropin() {
  command_exists systemctl || return 0
  [[ -f "$XUI_DB" ]] || return 0
  local sockets dropin_dir dropin_file rm_args
  sockets="$(sqlite3 -readonly "$XUI_DB" "SELECT DISTINCT substr(listen, 1, instr(listen || ',', ',') - 1) FROM inbounds WHERE listen LIKE '/%' AND json_valid(stream_settings)=1 AND json_extract(stream_settings,'$.network')='xhttp';" 2>/dev/null || true)"
  [[ -n "$sockets" ]] || return 0
  dropin_dir="/etc/systemd/system/x-ui.service.d"
  dropin_file="$dropin_dir/10-clean-xhttp-uds.conf"
  rm_args=""
  while IFS= read -r socket_path; do
    [[ -n "$socket_path" ]] || continue
    [[ "$socket_path" == /dev/shm/* || "$socket_path" == /run/* || "$socket_path" == /tmp/* ]] || continue
    rm_args="${rm_args} $(printf '%q' "$socket_path")"
  done <<<"$sockets"
  [[ -n "$rm_args" ]] || return 0
  mkdir -p "$dropin_dir"
  cat > "$dropin_file" <<EOF
[Service]
ExecStartPre=/bin/sh -c 'rm -f$rm_args'
EOF
  systemctl daemon-reload || true
  ok "x-ui systemd UDS cleanup installed: $dropin_file"
}

xui_disable_duplicate_xhttp_unix_listeners() {
  [[ -f "$XUI_DB" ]] || return 0
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET listen=''
    WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
      AND listen LIKE '/%'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
      AND (COALESCE(tag,'') LIKE '%-warp' OR lower(COALESCE(remark,'')) LIKE '%warp%');

    UPDATE inbounds
    SET enable=0
    WHERE id IN (
      SELECT i.id
      FROM inbounds i
      WHERE i.enable=1
        AND i.listen LIKE '/%'
        AND json_valid(i.stream_settings)=1
        AND json_extract(i.stream_settings,'$.network')='xhttp'
        AND i.id NOT IN (
          SELECT MIN(id)
          FROM inbounds
          WHERE enable=1
            AND listen LIKE '/%'
            AND json_valid(stream_settings)=1
            AND json_extract(stream_settings,'$.network')='xhttp'
          GROUP BY substr(listen, 1, instr(listen || ',', ',') - 1)
        )
    );
  " 2>/dev/null || true
}

xui_repair_client_traffic_rows() {
  [[ -f "$XUI_DB" ]] || return 0
  local rows inbound_id protocol settings client_rows email enable exact_count email_count
  rows="$(sqlite3 -readonly -separator $'\t' "$XUI_DB" "SELECT id, protocol, settings FROM inbounds WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2') AND json_valid(settings)=1;" 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0
  while IFS=$'\t' read -r inbound_id protocol settings; do
    [[ -n "$inbound_id" && -n "$settings" ]] || continue
    client_rows="$(jq -r '
      (.clients // [])
      | map(select((.email // "") != ""))
      | .[]
      | [(.email // ""), (if (.enable // true) then 1 else 0 end)]
      | @tsv
    ' <<<"$settings" 2>/dev/null || true)"
    [[ -n "$client_rows" ]] || continue
    while IFS=$'\t' read -r email enable; do
      [[ -n "$email" ]] || continue
      exact_count="$(sqlite3 -readonly "$XUI_DB" "SELECT COUNT(*) FROM client_traffics WHERE inbound_id=$inbound_id AND email=$(sql_quote "$email");" 2>/dev/null || printf '0')"
      if [[ "$exact_count" == "0" ]]; then
        email_count="$(sqlite3 -readonly "$XUI_DB" "SELECT COUNT(*) FROM client_traffics WHERE email=$(sql_quote "$email");" 2>/dev/null || printf '0')"
        if [[ "$email_count" == "1" ]]; then
          sqlite3 "$XUI_DB" "UPDATE client_traffics SET inbound_id=$inbound_id, enable=${enable:-1} WHERE email=$(sql_quote "$email");" 2>/dev/null || true
        else
          sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, ${enable:-1}, $(sql_quote "$email"), 0, 0, 0, 0, 0);" 2>/dev/null || true
        fi
      else
        sqlite3 "$XUI_DB" "UPDATE client_traffics SET enable=${enable:-1} WHERE inbound_id=$inbound_id AND email=$(sql_quote "$email");" 2>/dev/null || true
      fi
    done <<<"$client_rows"
  done <<<"$rows"
  ok "x-ui client traffic rows repaired"
}

nh_generate() {
  die "Legacy panel profile generation was removed. Create NaiveProxy and Mieru users in RIXXX Panel."
}
combined_generate() {
  warn "Legacy combined subscription generation was removed; use RIXXX Panel for NaiveProxy/Mieru and x-ui subscription for Xray links."
  return 0
}
configure_nginx_subscription() {
  return 0
}
XUI_STOPPED_FOR_DB_UPDATE=0
if [[ "$CREATE_XUI" == "1" && "$RELOAD_SERVICES" == "1" ]] && command_exists systemctl; then
  info "Stopping x-ui before database profile update"
  systemctl stop x-ui 2>/dev/null || true
  xui_cleanup_unix_sockets
  XUI_STOPPED_FOR_DB_UPDATE=1
fi

if [[ "$CREATE_XUI" == "1" ]]; then
  xui_add_clients
  xui_repair_client_traffic_rows
  xui_disable_duplicate_xhttp_unix_listeners
  xui_install_uds_cleanup_dropin
  xui_cleanup_unix_sockets
fi

if [[ "$CREATE_NH" == "1" ]]; then
  die "Legacy panel profile generation was removed; create NaiveProxy/Mieru users in RIXXX Panel"
fi
XUI_STARTED_AFTER_DB_UPDATE=0
if [[ "$CREATE_XUI" == "1" && "$RELOAD_SERVICES" == "1" && "$XUI_STOPPED_FOR_DB_UPDATE" == "1" ]] && command_exists systemctl; then
  info "Starting x-ui after database profile update"
  xui_cleanup_unix_sockets
  if systemctl start x-ui; then
    sleep 2
    XUI_STARTED_AFTER_DB_UPDATE=1
    XUI_STOPPED_FOR_DB_UPDATE=0
  else
    warn "x-ui start failed after database profile update"
  fi
fi

if [[ "$RELOAD_SERVICES" == "1" ]]; then
  info "Reloading services"
  if [[ "$CREATE_XUI" == "1" && "$XUI_STARTED_AFTER_DB_UPDATE" != "1" ]] && command_exists systemctl; then
    [[ "$XUI_STOPPED_FOR_DB_UPDATE" == "1" ]] || systemctl stop x-ui 2>/dev/null || true
    xui_cleanup_unix_sockets
    systemctl start x-ui || warn "x-ui start failed"
  fi
fi

printf '\nProfile generation complete\n'
printf '%s\n' '---------------------------'
if [[ "$CREATE_XUI" == "1" ]]; then
  cat <<EOF
x-ui:
  standard generated clients: ${XUI_CREATE_DIRECT} (${COUNT} per selected preset inbound when enabled)
  WARP mirror inbounds: ${XUI_CREATE_WARP_INBOUNDS} (${COUNT} clients per mirror; routing manual)
  WARP mirror enabled: ${XUI_WARP_INBOUNDS_ENABLE}
  subId mode: ${XUI_SUB_ID_MODE}
  common subId (only common mode): ${XUI_COMMON_SUB_ID}
  replace existing clients: ${XUI_REPLACE_CLIENTS}
  WARP routing: ${XUI_ENABLE_WARP_ROUTING}
  WARP auto-install: ${XUI_AUTO_INSTALL_WARP}
  WARP template DB apply: ${XUI_APPLY_WARP_TEMPLATE}
  WARP template cleanup: ${XUI_CLEANUP_WARP_TEMPLATE}
  WARP outbound: ${WARP_OUTBOUND_TAG}
  WARP proxy: ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
  WARP inbound filter: ${WARP_INBOUND_TAG}
  WARP routed domains: ${WARP_AI_DOMAINS}
  WARP snippet: /etc/x-ui/warp-generated-routing.json
  x-ui report: /etc/x-ui/generated-clients.txt
EOF
fi

cat <<EOF
RIXXX:
  NaiveProxy users: managed in RIXXX Panel
  Mieru users: managed in RIXXX Panel
EOF

cat <<EOF
Backup:
  ${backup_dir}
EOF
