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
NH_CONFIG="${NH_CONFIG:-/opt/panel-naive-hy2/panel/data/config.json}"
CADDYFILE="${CADDYFILE:-/etc/caddy-nh/Caddyfile}"
HYSTERIA_CONFIG="${HYSTERIA_CONFIG:-/etc/hysteria/config.yaml}"
NH_PROFILE_MAP="${NH_PROFILE_MAP:-/etc/nh-panel/generated-profile-map.json}"
NH_SUBSCRIPTION_DIR="${NH_SUBSCRIPTION_DIR:-/opt/panel-naive-hy2/subscriptions}"
NH_SUBSCRIPTION_TOKEN_FILE="${NH_SUBSCRIPTION_TOKEN_FILE:-/etc/nh-panel/subscription-token}"
NH_SUBSCRIPTION_NGINX="${NH_SUBSCRIPTION_NGINX:-1}"
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
CREATE_NH="${CREATE_NH:-1}"
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
  sudo bash generate-profiles.sh --nh-only --yes
  sudo bash generate-profiles.sh --combined-only --yes
  sudo bash generate-profiles.sh --install-warp --yes

Creates:
  x-ui:  COUNT standard clients on every selected preset inbound.
         Default subscriptions: one subId per client index.
  NHM:   COUNT NaiveProxy profiles and COUNT Hysteria2 profiles.
         Subscription files are written to ${NH_SUBSCRIPTION_DIR}.

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
  --combined-only: refresh combined subscription files only; do not edit x-ui or NHM users
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --nh-config) NH_CONFIG="${2:-}"; shift 2 ;;
    --caddyfile) CADDYFILE="${2:-}"; shift 2 ;;
    --hysteria-config) HYSTERIA_CONFIG="${2:-}"; shift 2 ;;
    --subscription-dir) NH_SUBSCRIPTION_DIR="${2:-}"; shift 2 ;;
    --no-nginx-subscription) NH_SUBSCRIPTION_NGINX=0; shift ;;
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
    --nh-only) CREATE_XUI=0; CREATE_NH=1; shift ;;
    --combined-only) COMBINED_ONLY=1; CREATE_XUI=0; CREATE_NH=0; RELOAD_SERVICES=0; shift ;;
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
if [[ "$COMBINED_ONLY" == "1" ]]; then
  [[ -f "$NH_CONFIG" ]] || die "NHM config not found: $NH_CONFIG"
fi

if [[ "$CREATE_XUI" == "1" && "$XUI_ENABLE_WARP_ROUTING" == "1" && "$XUI_AUTO_INSTALL_WARP" == "1" ]]; then
  ensure_warp_local_proxy "$SCRIPT_DIR"
fi

backup_dir="/opt/unified-proxy-manager/backups/profiles-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$XUI_DB" "$NH_CONFIG" "$CADDYFILE" "$HYSTERIA_CONFIG" "$NH_PROFILE_MAP" /etc/nginx/snippets/nh-subscriptions.conf /etc/nginx/snippets/includes.conf /etc/nginx/stream-enabled/stream.conf /etc/nginx/stream-enabled/upm-xui-reality.conf; do
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
  info "Creating NHM NaiveProxy and Hysteria2 profiles"
  [[ -f "$NH_CONFIG" ]] || die "NHM config not found: $NH_CONFIG"

  mkdir -p "$(dirname "$NH_SUBSCRIPTION_TOKEN_FILE")"
  if [[ -s "$NH_SUBSCRIPTION_TOKEN_FILE" ]]; then
    NH_SUBSCRIPTION_TOKEN="$(tr -dc 'A-Za-z0-9._-' < "$NH_SUBSCRIPTION_TOKEN_FILE" | head -c 128)"
  else
    NH_SUBSCRIPTION_TOKEN="$(openssl rand -hex 24)"
    upm_install_secret 0600 "$NH_SUBSCRIPTION_TOKEN_FILE" "$NH_SUBSCRIPTION_TOKEN" \
      || die "Failed to write subscription token atomically"
  fi
  [[ -n "$NH_SUBSCRIPTION_TOKEN" ]] || die "Could not create NHM subscription token"
  chmod 0600 "$NH_SUBSCRIPTION_TOKEN_FILE" 2>/dev/null || true

  COUNT="$COUNT" PREFIX="$PREFIX" NH_CONFIG="$NH_CONFIG" CADDYFILE="$CADDYFILE" HYSTERIA_CONFIG="$HYSTERIA_CONFIG" NH_PROFILE_MAP="$NH_PROFILE_MAP" NH_SUBSCRIPTION_DIR="$NH_SUBSCRIPTION_DIR" NH_SUBSCRIPTION_TOKEN="$NH_SUBSCRIPTION_TOKEN" SCRIPT_DIR="$SCRIPT_DIR" node <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const path = require('path');
const crypto = require('crypto');

const count = parseInt(process.env.COUNT || '4', 10);
const prefix = process.env.PREFIX || 'auto';
const cfgPath = process.env.NH_CONFIG;
const caddyfile = process.env.CADDYFILE;
const hyPath = process.env.HYSTERIA_CONFIG;
const profileMapPath = process.env.NH_PROFILE_MAP || '/etc/nh-panel/generated-profile-map.json';
const reportPath = '/opt/panel-naive-hy2/generated-profiles.txt';
const subRoot = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const subToken = process.env.NH_SUBSCRIPTION_TOKEN || 'missing-token';
const subDir = path.join(subRoot, subToken);

function pass() {
  return cp.execSync("openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20", { encoding: 'utf8', shell: '/bin/bash' }).trim();
}

function token(len = 12) {
  return crypto.randomBytes(Math.ceil(len / 2))
    .toString('hex')
    .slice(0, len);
}

function loadProfileMap() {
  try {
    const parsed = JSON.parse(fs.readFileSync(profileMapPath, 'utf8'));
    if (parsed && Array.isArray(parsed.profiles)) return parsed;
  } catch (_) {}
  return { version: 1, profiles: [] };
}

function saveProfileMap(map) {
  fs.mkdirSync(path.dirname(profileMapPath), { recursive: true, mode: 0o700 });
  fs.writeFileSync(profileMapPath, JSON.stringify(map, null, 2) + '\n', { mode: 0o600 });
  try { fs.chmodSync(profileMapPath, 0o600); } catch (_) {}
}

function ensureProfileMap(map, discoveredSubIds = []) {
  const byIndex = new Map(map.profiles.map(p => [Number(p.index), p]));
  const bySubId = new Map(map.profiles.map(p => [String(p.subId || ''), p]).filter(([subId]) => subId));
  const profiles = [];
  for (let i = 1; i <= count; i += 1) {
    const n = String(i).padStart(2, '0');
    const discoveredSubId = String(discoveredSubIds[i - 1] || '').trim();
    const existing = (discoveredSubId && bySubId.get(discoveredSubId)) || byIndex.get(i) || {};
    profiles.push({
      ...existing,
      index: i,
      subId: discoveredSubId || existing.subId || `${prefix}-${n}`,
      subscriptionId: existing.subscriptionId || `sub-${token(14)}`,
      naiveUsername: existing.naiveUsername || `naive-${token(10)}`,
      hy2Username: existing.hy2Username || `hy2-${token(10)}`
    });
  }
  map.version = 1;
  map.profiles = profiles;
  saveProfileMap(map);
  return map;
}

const profileMap = ensureProfileMap(loadProfileMap());
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
cfg.stack = cfg.stack || {};
cfg.stack.naive = true;
cfg.stack.hy2 = true;
cfg.naiveUsers = Array.isArray(cfg.naiveUsers) ? cfg.naiveUsers : [];
cfg.hy2Users = Array.isArray(cfg.hy2Users) ? cfg.hy2Users : [];
cfg.installed = cfg.installed !== false;
const now = new Date().toISOString();
const generatedNaive = [];
const generatedHy2 = [];
const mappedNaiveNames = new Set(profileMap.profiles.map(p => String(p.naiveUsername || '')).filter(Boolean));
const mappedHy2Names = new Set(profileMap.profiles.map(p => String(p.hy2Username || '')).filter(Boolean));
const generatedNaiveRe = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-naive-[0-9]+$`);
const generatedHy2Re = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-hy2-[0-9]+$`);
const existingGeneratedNaive = new Map(
  cfg.naiveUsers
    .filter(u => mappedNaiveNames.has(String(u.username || '')) || generatedNaiveRe.test(String(u.username || '')))
    .map(u => [String(u.username), u])
);
const existingGeneratedHy2 = new Map(
  cfg.hy2Users
    .filter(u => mappedHy2Names.has(String(u.username || '')) || generatedHy2Re.test(String(u.username || '')))
    .map(u => [String(u.username), u])
);

cfg.naiveUsers = cfg.naiveUsers.filter(u => !mappedNaiveNames.has(String(u.username || '')) && !generatedNaiveRe.test(String(u.username || '')));
cfg.hy2Users = cfg.hy2Users.filter(u => !mappedHy2Names.has(String(u.username || '')) && !generatedHy2Re.test(String(u.username || '')));

for (const profile of profileMap.profiles) {
  const legacyIndex = String(profile.index).padStart(2, '0');
  const naiveName = profile.naiveUsername;
  const hyName = profile.hy2Username;
  const oldNaive = existingGeneratedNaive.get(naiveName) || existingGeneratedNaive.get(`${prefix}-naive-${legacyIndex}`) || {};
  const oldHy = existingGeneratedHy2.get(hyName) || existingGeneratedHy2.get(`${prefix}-hy2-${legacyIndex}`) || {};
  const naiveUser = {
    ...oldNaive,
    username: naiveName,
    password: oldNaive.password || pass(),
    createdAt: oldNaive.createdAt || now
  };
  const hyUser = {
    ...oldHy,
    username: hyName,
    password: oldHy.password || pass(),
    createdAt: oldHy.createdAt || now
  };
  cfg.naiveUsers.push(naiveUser);
  cfg.hy2Users.push(hyUser);
  generatedNaive.push(naiveUser);
  generatedHy2.push(hyUser);
}

if (fs.existsSync(caddyfile)) {
  let content = fs.readFileSync(caddyfile, 'utf8');
  const authLines = cfg.naiveUsers
    .map(u => `    basic_auth ${u.username} ${u.password}`)
    .join('\n');
  const nextContent = content.replace(/(forward_proxy\s*\{\n)([\s\S]*?)(\n\s*hide_ip)/, `$1${authLines}$3`);
  if (nextContent === content && !content.includes(authLines)) {
    throw new Error(`Caddyfile forward_proxy auth block was not found: ${caddyfile}`);
  }
  content = nextContent;
  fs.writeFileSync(`${caddyfile}.new`, content);
  fs.renameSync(`${caddyfile}.new`, caddyfile);
}

function loadYaml() {
  const possible = [
    '/opt/panel-naive-hy2/panel/node_modules/js-yaml',
    `${process.env.SCRIPT_DIR}/components/nh-panel/upstream/panel/node_modules/js-yaml`,
    'js-yaml'
  ];
  for (const mod of possible) {
    try { return require(mod); } catch (_) {}
  }
  return null;
}

function hy2AuthYaml(users) {
  const lines = ['auth:', '  type: userpass', '  userpass:'];
  for (const u of users) {
    lines.push(`    ${u.username}: ${JSON.stringify(String(u.password || ''))}`);
  }
  return lines.join('\n') + '\n';
}

function patchHy2AuthText(content, users) {
  const authBlock = hy2AuthYaml(users);
  if (/^auth:\n/m.test(content)) {
    return content.replace(/^auth:\n(?:[ \t].*(?:\n|$))*/m, authBlock);
  }
  return `${authBlock}\n${content}`;
}

if (fs.existsSync(hyPath)) {
  const yaml = loadYaml();
  if (!yaml) {
    const content = fs.readFileSync(hyPath, 'utf8');
    fs.writeFileSync(hyPath, patchHy2AuthText(content, cfg.hy2Users));
  } else {
    const hy = yaml.load(fs.readFileSync(hyPath, 'utf8')) || {};
    hy.auth = hy.auth || {};
    hy.auth.type = 'userpass';
    hy.auth.userpass = {};
    for (const u of cfg.hy2Users) hy.auth.userpass[u.username] = u.password;
    fs.writeFileSync(hyPath, yaml.dump(hy, { lineWidth: 120, quotingType: '"' }));
  }
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2), { mode: 0o600 });
try { fs.chmodSync(cfgPath, 0o600); } catch (_) {}

const domain = cfg.domain || 'DOMAIN_NOT_SET';
const generatedNaiveLinks = generatedNaive.map(u => `naive+https://${encodeURIComponent(u.username)}:${encodeURIComponent(u.password)}@${domain}:443#${encodeURIComponent(u.username)}`);
const hy2UserpassAuth = u => `${encodeURIComponent(u.username)}:${encodeURIComponent(u.password)}`;
const generatedHy2Links = generatedHy2.map(u => `hysteria2://${hy2UserpassAuth(u)}@${domain}:443?sni=${domain}&insecure=0#${encodeURIComponent(u.username)}`);
const naiveLinks = generatedNaiveLinks;
const hy2Links = generatedHy2Links;
const lines = [];
lines.push('Generated NHM profiles');
lines.push('======================');
lines.push('');
lines.push('NaiveProxy:');
for (const link of generatedNaiveLinks) lines.push(link);
lines.push('');
lines.push('Hysteria2:');
for (const link of generatedHy2Links) lines.push(link);
lines.push('');
lines.push(`Profile map: ${profileMapPath}`);
lines.push('');
lines.push('Per-client subscription names:');
for (const profile of profileMap.profiles) {
  lines.push(`${profile.subId} -> ${profile.subscriptionId}.txt`);
}
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, lines.join('\n') + '\n', { mode: 0o600 });

function b64(s) {
  return Buffer.from(s, 'utf8').toString('base64');
}

function singBoxOutboundFromLink(link, index) {
  if (link.startsWith('naive+https://')) {
    const raw = link.slice('naive+'.length);
    const url = new URL(raw);
    return {
      type: 'naive',
      tag: `naive-${index}`,
      server: url.hostname,
      server_port: Number(url.port || 443),
      username: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password)
    };
  }
  if (link.startsWith('hysteria2://')) {
    const url = new URL(link);
    const auth = url.password
      ? `${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`
      : decodeURIComponent(url.username);
    return {
      type: 'hysteria2',
      tag: `hy2-${index}`,
      server: url.hostname,
      server_port: Number(url.port || 443),
      password: auth,
      tls: {
        enabled: true,
        server_name: url.searchParams.get('sni') || url.hostname,
        insecure: url.searchParams.get('insecure') === '1'
      }
    };
  }
  return null;
}

const allLinks = [...naiveLinks, ...hy2Links];
const singBox = {
  log: { level: 'info' },
  outbounds: allLinks.map(singBoxOutboundFromLink).filter(Boolean)
};

for (const name of ['naive.txt', 'hy2.txt', 'all.txt', 'naive.b64', 'hy2.b64', 'all.b64', 'sing-box.json']) {
  try { fs.unlinkSync(path.join(subRoot, name)); } catch (_) {}
  try { fs.unlinkSync(path.join(subDir, name)); } catch (_) {}
}
fs.mkdirSync(subDir, { recursive: true, mode: 0o755 });
fs.writeFileSync(`${subDir}/naive.txt`, naiveLinks.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/hy2.txt`, hy2Links.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/all.txt`, allLinks.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/naive.b64`, b64(naiveLinks.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/hy2.b64`, b64(hy2Links.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/all.b64`, b64(allLinks.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/sing-box.json`, JSON.stringify(singBox, null, 2) + '\n', { mode: 0o644 });
if (generatedNaive.length !== count || generatedHy2.length !== count) {
  throw new Error(`Generated count mismatch: naive=${generatedNaive.length}, hy2=${generatedHy2.length}, expected=${count}`);
}
NODE

  local sub_dir="${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  if [[ -d "$sub_dir" ]]; then
    if getent group www-data >/dev/null 2>&1; then
      chgrp -R www-data "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      chmod 0750 "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      find "$sub_dir" -type f -exec chmod 0640 {} + 2>/dev/null || true
    else
      chmod 0755 "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      find "$sub_dir" -type f -exec chmod 0644 {} + 2>/dev/null || true
      warn "www-data group not found; subscription files kept world-readable for nginx compatibility"
    fi
  fi

  if [[ -f "$CADDYFILE" ]]; then
    if command_exists caddy-nh; then
      caddy-nh validate --config "$CADDYFILE" >/dev/null || die "Generated Caddyfile is invalid"
    elif command_exists caddy; then
      caddy validate --config "$CADDYFILE" >/dev/null || die "Generated Caddyfile is invalid"
    fi
  fi
  ok "NHM config updated: $COUNT NaiveProxy + $COUNT Hysteria2 profiles"
  ok "NHM generated links saved: /opt/panel-naive-hy2/generated-profiles.txt"
  ok "NHM subscriptions saved: ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  configure_nginx_subscription
}

combined_generate() {
  [[ -f "$XUI_DB" ]] || { warn "x-ui database not found; combined subscription skipped"; return 0; }
  [[ -f "$NH_CONFIG" ]] || { warn "NHM config not found; combined subscription skipped"; return 0; }

  if [[ -z "${NH_SUBSCRIPTION_TOKEN:-}" ]]; then
    if [[ -s "$NH_SUBSCRIPTION_TOKEN_FILE" ]]; then
      NH_SUBSCRIPTION_TOKEN="$(tr -dc 'A-Za-z0-9._-' < "$NH_SUBSCRIPTION_TOKEN_FILE" | head -c 128)"
    else
      warn "NHM subscription token missing; combined subscription skipped"
      return 0
    fi
  fi

  COUNT="$COUNT" PREFIX="$PREFIX" XUI_DB="$XUI_DB" NH_CONFIG="$NH_CONFIG" NH_PROFILE_MAP="$NH_PROFILE_MAP" NH_SUBSCRIPTION_DIR="$NH_SUBSCRIPTION_DIR" NH_SUBSCRIPTION_TOKEN="$NH_SUBSCRIPTION_TOKEN" node <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const path = require('path');
const crypto = require('crypto');

const count = parseInt(process.env.COUNT || '4', 10);
const prefix = process.env.PREFIX || 'auto';
const xuiDb = process.env.XUI_DB;
const nhConfig = process.env.NH_CONFIG;
const profileMapPath = process.env.NH_PROFILE_MAP || '/etc/nh-panel/generated-profile-map.json';
const subRoot = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const subToken = process.env.NH_SUBSCRIPTION_TOKEN || '';
const subDir = path.join(subRoot, subToken);

function b64(s) {
  return Buffer.from(s, 'utf8').toString('base64');
}

function encode(v) {
  return encodeURIComponent(String(v ?? ''));
}

function token(len = 12) {
  return crypto.randomBytes(Math.ceil(len / 2))
    .toString('hex')
    .slice(0, len);
}

function loadProfileMap() {
  try {
    const parsed = JSON.parse(fs.readFileSync(profileMapPath, 'utf8'));
    if (parsed && Array.isArray(parsed.profiles)) return parsed;
  } catch (_) {}
  return { version: 1, profiles: [] };
}

function saveProfileMap(map) {
  fs.mkdirSync(path.dirname(profileMapPath), { recursive: true, mode: 0o700 });
  fs.writeFileSync(profileMapPath, JSON.stringify(map, null, 2) + '\n', { mode: 0o600 });
  try { fs.chmodSync(profileMapPath, 0o600); } catch (_) {}
}

function ensureProfileMap(map, discoveredSubIds = []) {
  const byIndex = new Map(map.profiles.map(p => [Number(p.index), p]));
  const bySubId = new Map(map.profiles.map(p => [String(p.subId || ''), p]).filter(([subId]) => subId));
  const profiles = [];
  for (let i = 1; i <= count; i += 1) {
    const n = String(i).padStart(2, '0');
    const discoveredSubId = String(discoveredSubIds[i - 1] || '').trim();
    const existing = (discoveredSubId && bySubId.get(discoveredSubId)) || byIndex.get(i) || {};
    profiles.push({
      ...existing,
      index: i,
      subId: discoveredSubId || existing.subId || `${prefix}-${n}`,
      subscriptionId: existing.subscriptionId || `sub-${token(14)}`,
      naiveUsername: existing.naiveUsername || `naive-${token(10)}`,
      hy2Username: existing.hy2Username || `hy2-${token(10)}`
    });
  }
  map.version = 1;
  map.profiles = profiles;
  saveProfileMap(map);
  return map;
}

function cleanHost(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    if (/^https?:\/\//i.test(raw)) return new URL(raw).hostname;
  } catch (_) {}
  return raw.replace(/^\[|\]$/g, '').split('/')[0].split(':')[0];
}

function firstEnabledClient(settings, wantedSubId) {
  const clients = Array.isArray(settings.clients) ? settings.clients : [];
  return clients.filter(c => c && c.enable !== false && String(c.subId || '') === wantedSubId);
}

function endpoint(stream, inboundPort) {
  const external = Array.isArray(stream.externalProxy) ? stream.externalProxy[0] : null;
  const server = cleanHost(external && external.dest);
  const port = Number((external && external.port) || inboundPort || 443);
  return {
    server,
    port,
    tls: external ? String(external.forceTls || '').toLowerCase() : ''
  };
}

function addParam(params, key, value) {
  if (value !== undefined && value !== null && String(value) !== '') params.set(key, String(value));
}

function vlessLink(row, client) {
  const stream = JSON.parse(row.stream_settings || '{}');
  const ep = endpoint(stream, row.port);
  if (!ep.server || !client.id) return null;

  const network = String(stream.network || 'tcp');
  const security = String(stream.security || 'none');
  const params = new URLSearchParams();
  params.set('type', network);
  params.set('encryption', 'none');

  if (security === 'reality') {
    const reality = stream.realitySettings || {};
    const settings = reality.settings || {};
    const serverNames = Array.isArray(reality.serverNames) ? reality.serverNames : [];
    if (!serverNames[0]) {
      console.error(`WARN: REALITY inbound port=${row.port} has empty serverNames; skipping link for client ${client.email || client.id}`);
      return null;
    }
    if (!settings.publicKey) {
      console.error(`WARN: REALITY inbound port=${row.port} has empty publicKey; skipping link for client ${client.email || client.id}`);
      return null;
    }
    params.set('security', 'reality');
    addParam(params, 'pbk', settings.publicKey);
    addParam(params, 'fp', settings.fingerprint || 'chrome');
    addParam(params, 'sni', serverNames[0]);
    const shortIds = Array.isArray(reality.shortIds) ? reality.shortIds : [];
    const sid = shortIds.length > 0 ? String(shortIds[0]) : '';
    if (sid !== '' && !/^[0-9a-f]{0,16}$/i.test(sid)) {
      console.error(`WARN: REALITY shortId "${sid}" is not valid hex; using empty sid`);
      params.set('sid', '');
    } else if (shortIds.length > 0) {
      params.set('sid', sid);
    }
    addParam(params, 'spx', settings.spiderX || '/');
    addParam(params, 'flow', client.flow);
  } else {
    const sec = ep.tls === 'tls' || ep.tls === 'same' || [443, 8443].includes(ep.port) ? 'tls' : security;
    params.set('security', sec);
    if (sec === 'tls') {
      // uTLS masking params so the client mimics a real browser TLS handshake
      const tls = stream.tlsSettings || {};
      addParam(params, 'sni', tls.serverName || stream.wsSettings?.host || ep.server);
      addParam(params, 'fp', tls.fingerprint || 'chrome');
      addParam(params, 'alpn', Array.isArray(tls.alpn) ? tls.alpn.join(',') : '');
    }
  }

  if (network === 'ws') {
    const ws = stream.wsSettings || {};
    addParam(params, 'path', ws.path);
    addParam(params, 'host', ws.host);
  } else if (network === 'grpc') {
    const grpc = stream.grpcSettings || {};
    addParam(params, 'serviceName', grpc.serviceName);
    addParam(params, 'authority', grpc.authority);
  } else if (network === 'xhttp') {
    const xhttp = stream.xhttpSettings || {};
    addParam(params, 'path', xhttp.path);
    addParam(params, 'host', xhttp.host);
    addParam(params, 'mode', xhttp.mode);
  }

  return `vless://${encode(client.id)}@${ep.server}:${ep.port}?${params.toString()}#${encode(client.email || row.remark || 'x-ui')}`;
}

function trojanLink(row, client) {
  const stream = JSON.parse(row.stream_settings || '{}');
  const ep = endpoint(stream, row.port);
  const password = client.password || client.id;
  if (!ep.server || !password) return null;

  const network = String(stream.network || 'tcp');
  const security = String(stream.security || 'none');
  const params = new URLSearchParams();
  params.set('type', network);
  if (security === 'reality') {
    const reality = stream.realitySettings || {};
    const settings = reality.settings || {};
    const serverNames = Array.isArray(reality.serverNames) ? reality.serverNames : [];
    params.set('security', 'reality');
    addParam(params, 'pbk', settings.publicKey);
    addParam(params, 'fp', settings.fingerprint || 'random');
    addParam(params, 'sni', serverNames[0]);
    addParam(params, 'sid', Array.isArray(reality.shortIds) ? reality.shortIds[0] : '');
    addParam(params, 'spx', settings.spiderX || '/');
  } else {
    const sec = ep.tls === 'tls' || ep.tls === 'same' || [443, 8443].includes(ep.port) ? 'tls' : security;
    params.set('security', sec);
    if (sec === 'tls') {
      const tls = stream.tlsSettings || {};
      addParam(params, 'sni', tls.serverName || stream.wsSettings?.host || ep.server);
      addParam(params, 'fp', tls.fingerprint || 'chrome');
      addParam(params, 'alpn', Array.isArray(tls.alpn) ? tls.alpn.join(',') : '');
    }
  }

  if (network === 'grpc') {
    const grpc = stream.grpcSettings || {};
    addParam(params, 'serviceName', grpc.serviceName);
    addParam(params, 'authority', grpc.authority);
  } else if (network === 'ws') {
    const ws = stream.wsSettings || {};
    addParam(params, 'path', ws.path);
    addParam(params, 'host', ws.host);
  }

  return `trojan://${encode(password)}@${ep.server}:${ep.port}?${params.toString()}#${encode(client.email || row.remark || 'x-ui')}`;
}

function shadowsocksLink(row, client) {
  const stream = JSON.parse(row.stream_settings || '{}');
  const settings = JSON.parse(row.settings || '{}');
  const ep = endpoint(stream, row.port);
  if (!ep.server || !settings.method || !settings.password || !client.password) return null;
  const userInfo = `${settings.method}:${settings.password}:${client.password}`;
  return `ss://${Buffer.from(userInfo, 'utf8').toString('base64')}@${ep.server}:${ep.port}?type=tcp#${encode(client.email || row.remark || 'ss')}`;
}

function hysteria2Link(row, client) {
  const stream = JSON.parse(row.stream_settings || '{}');
  const ep = endpoint(stream, row.port);
  const auth = client.auth || client.password;
  if (!ep.server || !auth) return null;
  const finalmask = stream.finalmask?.udp?.[0] || {};
  const fm = {
    udp: [{
      type: finalmask.type,
      settings: { password: finalmask.settings?.password }
    }]
  };
  const params = new URLSearchParams();
  params.set('insecure', '1');
  params.set('security', 'tls');
  params.set('fp', 'chrome');
  params.set('alpn', 'h3');
  params.set('fm', JSON.stringify(fm));
  addParam(params, 'sni', stream.tlsSettings?.serverName || ep.server);
  addParam(params, 'obfs', finalmask.type);
  addParam(params, 'obfs-password', finalmask.settings?.password);
  return `hy2://${encode(auth)}@${ep.server}:${ep.port}/?${params.toString()}#${encode(client.email || row.remark || 'hy2')}`;
}

function xuiLink(row, client) {
  if (row.protocol === 'trojan') return trojanLink(row, client);
  if (row.protocol === 'shadowsocks') return shadowsocksLink(row, client);
  if (row.protocol === 'hysteria' || row.protocol === 'hysteria2') return hysteria2Link(row, client);
  return vlessLink(row, client);
}

function isStableV2rayNLink(row) {
  try {
    const stream = JSON.parse(row.stream_settings || '{}');
    const network = String(stream.network || 'tcp');
    const security = String(stream.security || 'none');
    return network !== 'xhttp' && (row.protocol !== 'vless' || network === 'ws' || network === 'grpc' || (network === 'tcp' && security === 'reality'));
  } catch (_) {
    return false;
  }
}

function xuiRows() {
  const sql = `
    SELECT COALESCE(json_group_array(json_object(
      'id', id,
      'remark', COALESCE(remark, ''),
      'port', port,
      'protocol', protocol,
      'settings', settings,
      'stream_settings', stream_settings,
      'tag', COALESCE(tag, '')
    )), '[]')
    FROM (
      SELECT id, remark, port, protocol, settings, stream_settings, tag
      FROM inbounds
      WHERE enable=1
        AND protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
        AND json_valid(settings)=1
        AND json_valid(stream_settings)=1
      ORDER BY id
    );
  `;
  const out = cp.execFileSync('sqlite3', ['-readonly', xuiDb, sql], { encoding: 'utf8' });
  return JSON.parse(out || '[]');
}

function discoverXuiSubIds(rows) {
  const observed = new Map();
  for (const [rowIndex, row] of rows.entries()) {
    let settings;
    try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
    const clients = Array.isArray(settings.clients) ? settings.clients : [];
    const seen = new Set();
    let position = 0;
    for (const client of clients) {
      if (!client || client.enable === false) continue;
      const subId = String(client.subId || '').trim();
      if (!subId || seen.has(subId)) continue;
      seen.add(subId);
      const item = observed.get(subId) || { subId, rows: 0, positions: [], firstRow: rowIndex };
      item.rows += 1;
      item.positions.push(position);
      item.firstRow = Math.min(item.firstRow, rowIndex);
      observed.set(subId, item);
      position += 1;
    }
  }
  const entries = Array.from(observed.values()).map(item => ({
    ...item,
    avgPosition: item.positions.reduce((sum, pos) => sum + pos, 0) / item.positions.length
  }));
  if (!entries.length) return [];
  const maxRows = Math.max(...entries.map(item => item.rows));
  const primary = entries.filter(item => item.rows === maxRows);
  const secondary = entries.filter(item => item.rows !== maxRows);
  const byOrder = (a, b) => (
    a.avgPosition - b.avgPosition
    || b.rows - a.rows
    || a.firstRow - b.firstRow
    || a.subId.localeCompare(b.subId)
  );
  primary.sort(byOrder);
  secondary.sort(byOrder);
  const discovered = [...primary, ...secondary].slice(0, count).map(item => item.subId);
  if (discovered.length < count) {
    console.error(`WARN: discovered only ${discovered.length}/${count} x-ui subId values for combined subscriptions`);
  }
  const weak = discovered.filter(subId => (observed.get(subId)?.rows || 0) < maxRows);
  if (weak.length) {
    console.error(`WARN: some combined subscription subIds are not present on every selected inbound: ${weak.join(', ')}`);
  }
  return discovered;
}

let cachedXuiSettings = null;
function xuiSettings() {
  if (cachedXuiSettings) return cachedXuiSettings;
  const sql = `
    SELECT COALESCE(json_group_object(key, value), '{}')
    FROM settings
    WHERE key IN ('subPort','subPath');
  `;
  try {
    const out = cp.execFileSync('sqlite3', ['-readonly', xuiDb, sql], { encoding: 'utf8' });
    cachedXuiSettings = JSON.parse(out || '{}');
  } catch (_) {
    cachedXuiSettings = {};
  }
  return cachedXuiSettings;
}

function normalizeSubText(raw) {
  const text = String(raw || '').trim();
  if (!text || /<html/i.test(text)) return '';
  const supportedLinks = value => String(value || '')
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(s => /^(?:vless|trojan|ss|hysteria2|hy2):\/\//i.test(s))
    .join('\n');
  const direct = supportedLinks(text);
  if (direct) return direct;
  const compact = text.replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/=_-]+$/.test(compact)) return '';
  try {
    const decoded = Buffer.from(compact.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8').trim();
    return supportedLinks(decoded);
  } catch (_) {}
  return '';
}

function fetchXuiSubscription(subId) {
  const settings = xuiSettings();
  const subPort = String(settings.subPort || '').trim();
  let subPath = String(settings.subPath || '').trim();
  if (!subPort || !subPath) return '';
  if (!subPath.startsWith('/')) subPath = `/${subPath}`;
  if (!subPath.endsWith('/')) subPath = `${subPath}/`;
  const urls = [`https://127.0.0.1:${subPort}${subPath}${encodeURIComponent(subId)}`];
  for (const url of urls) {
    try {
      const raw = cp.execFileSync('curl', ['-kfsSL', '--max-time', '4', url], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      const normalized = normalizeSubText(raw);
      if (normalized) return normalized;
    } catch (_) {}
  }
  return '';
}

function xuiLinkLabel(link) {
  try {
    const url = new URL(String(link || ''));
    const scheme = url.protocol.replace(':', '').toLowerCase();
    if (scheme === 'trojan') {
      const type = (url.searchParams.get('type') || '').toLowerCase();
      return type === 'grpc' ? 'trojan-grpc' : 'trojan';
    }
    if (scheme === 'vless') {
      const type = (url.searchParams.get('type') || '').toLowerCase();
      const security = (url.searchParams.get('security') || '').toLowerCase();
      if (security === 'reality') return 'reality';
      if (type === 'xhttp' || type === 'splithttp') return 'xhttp';
      if (type === 'ws') return 'ws';
      if (type === 'grpc') return 'grpc';
      return type || 'vless';
    }
    return scheme || 'xui';
  } catch (_) {
    return 'xui';
  }
}

function renameLinkFragment(link, name) {
  const raw = String(link || '').trim();
  if (!raw) return raw;
  const hashIndex = raw.indexOf('#');
  const body = hashIndex >= 0 ? raw.slice(0, hashIndex) : raw;
  return `${body}#${encode(name)}`;
}

function renameXuiLinks(links, subId) {
  return links.map(link => renameLinkFragment(link, `${xuiLinkLabel(link)}-${subId}`));
}

function nhLinksBySubId() {
  const cfg = JSON.parse(fs.readFileSync(nhConfig, 'utf8'));
  const domain = cfg.domain || 'DOMAIN_NOT_SET';
  const bySubId = new Map();
  const naive = Array.isArray(cfg.naiveUsers) ? cfg.naiveUsers : [];
  const hy2 = Array.isArray(cfg.hy2Users) ? cfg.hy2Users : [];

  for (const profile of profileMap.profiles) {
    const i = Number(profile.index) || 0;
    if (!i) continue;
    const n = String(i).padStart(2, '0');
    const subId = String(profile.subId || `${prefix}-${n}`);
    const links = [];
    const nUser = naive.find(u => String(u.username || '') === String(profile.naiveUsername || ''))
      || naive.find(u => String(u.username || '') === `${prefix}-naive-${n}`);
    const hUser = hy2.find(u => String(u.username || '') === String(profile.hy2Username || ''))
      || hy2.find(u => String(u.username || '') === `${prefix}-hy2-${n}`);
    if (nUser) links.push(`naive+https://${encode(nUser.username)}:${encode(nUser.password)}@${domain}:443#${encode(`naive-${subId}`)}`);
    if (hUser) links.push(`hysteria2://${encode(hUser.username)}:${encode(hUser.password)}@${domain}:443?sni=${domain}&insecure=0#${encode(`hy2-${subId}`)}`);
    bySubId.set(subId, links);
  }
  return bySubId;
}

const rows = xuiRows();
const discoveredSubIds = discoverXuiSubIds(rows);
const profileMap = ensureProfileMap(loadProfileMap(), discoveredSubIds);
const profilesBySubId = new Map(profileMap.profiles.map(p => [String(p.subId), p]));
const bySubId = new Map();
for (const profile of profileMap.profiles) {
  bySubId.set(String(profile.subId), []);
}

for (const row of rows) {
  let settings;
  try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
  for (const subId of bySubId.keys()) {
    for (const client of firstEnabledClient(settings, subId)) {
      const link = xuiLink(row, client);
      if (link) bySubId.get(subId).push(link);
    }
  }
}

const nhBySubId = nhLinksBySubId();
const combinedAll = [];
const xrayAll = [];
const stableXrayAll = [];
fs.mkdirSync(subDir, { recursive: true, mode: 0o755 });

for (const [subId, links] of bySubId) {
  const profile = profilesBySubId.get(subId) || {};
  const subscriptionId = String(profile.subscriptionId || subId);
  const officialXuiText = links.length ? '' : fetchXuiSubscription(subId);
  const officialXuiLinks = officialXuiText ? officialXuiText.split(/\n/).filter(Boolean) : [];
  const xuiLinks = renameXuiLinks(links.length ? links : officialXuiLinks, subId);
  const combined = [...xuiLinks, ...(nhBySubId.get(subId) || [])];
  const text = combined.join('\n');
  const xrayText = xuiLinks.join('\n');
  const stableLinks = [];
  for (const row of rows) {
    if (!isStableV2rayNLink(row)) continue;
    let settings;
    try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
    for (const client of firstEnabledClient(settings, subId)) {
      const link = xuiLink(row, client);
      if (link) stableLinks.push(link);
    }
  }
  if (!stableLinks.length && officialXuiLinks.length) {
    stableLinks.push(...officialXuiLinks.filter(link => !/[?&]type=xhttp(?:&|$)/i.test(link) && !/[?&]type=splithttp(?:&|$)/i.test(link)));
  }
  const stableText = stableLinks.join('\n');
  for (const legacyName of [
    `${subId}.txt`,
    `${subId}.b64`,
    `${subId}-v2rayn.txt`,
    `${subId}-v2rayn.b64`,
    `${subId}-v2rayn-raw.txt`,
    `${subId}-v2rayn-stable.txt`
  ]) {
    try { fs.unlinkSync(path.join(subDir, legacyName)); } catch (_) {}
  }
  fs.writeFileSync(path.join(subDir, `${subscriptionId}.txt`), text + (text ? '\n' : ''), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subscriptionId}.b64`), b64(text), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subscriptionId}-v2rayn.txt`), b64(xrayText) + '\n', { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subscriptionId}-v2rayn.b64`), b64(xrayText), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subscriptionId}-v2rayn-raw.txt`), xrayText + (xrayText ? '\n' : ''), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subscriptionId}-v2rayn-stable.txt`), b64(stableText) + '\n', { mode: 0o644 });
  combinedAll.push(...combined);
  xrayAll.push(...links);
  stableXrayAll.push(...stableLinks);
}

const allText = combinedAll.join('\n');
const xrayText = xrayAll.join('\n');
const stableXrayText = stableXrayAll.join('\n');
fs.writeFileSync(path.join(subDir, 'combined.txt'), allText + (allText ? '\n' : ''), { mode: 0o644 });
fs.writeFileSync(path.join(subDir, 'combined.b64'), b64(allText), { mode: 0o644 });
fs.writeFileSync(path.join(subDir, 'v2rayn.txt'), b64(xrayText) + '\n', { mode: 0o644 });
fs.writeFileSync(path.join(subDir, 'v2rayn.b64'), b64(xrayText), { mode: 0o644 });
fs.writeFileSync(path.join(subDir, 'v2rayn-raw.txt'), xrayText + (xrayText ? '\n' : ''), { mode: 0o644 });
fs.writeFileSync(path.join(subDir, 'v2rayn-stable.txt'), b64(stableXrayText) + '\n', { mode: 0o644 });
NODE

  local sub_dir="${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  if [[ -d "$sub_dir" ]]; then
    if getent group www-data >/dev/null 2>&1; then
      chgrp -R www-data "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      chmod 0750 "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      find "$sub_dir" -type f -exec chmod 0640 {} + 2>/dev/null || true
    else
      chmod 0755 "${NH_SUBSCRIPTION_DIR%/}" "$sub_dir" 2>/dev/null || true
      find "$sub_dir" -type f -exec chmod 0644 {} + 2>/dev/null || true
    fi
  fi
  ok "Combined x-ui + NHM subscriptions saved with random per-client names from $NH_PROFILE_MAP"
  ok "v2rayN-safe x-ui subscription saved: ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN/v2rayn.txt"
}

configure_nginx_subscription() {
  [[ "$NH_SUBSCRIPTION_NGINX" == "1" ]] || return 0
  command_exists nginx || { warn "nginx is not installed; subscription files were created locally only"; return 0; }
  [[ -d /etc/nginx/conf.d ]] || { warn "/etc/nginx/conf.d not found; subscription files were created locally only"; return 0; }

  mkdir -p /etc/nginx/snippets
  cat > /etc/nginx/snippets/nh-subscriptions.conf <<EOF
location ^~ /sub/ {
    alias ${NH_SUBSCRIPTION_DIR%/}/;
    default_type text/plain;
    autoindex off;
    types {
        application/json json;
        text/plain txt b64;
    }
    add_header Cache-Control "no-store";
    add_header X-Content-Type-Options "nosniff" always;
}
EOF

  local conf="/etc/nginx/conf.d/nh-subscriptions.conf"
  local panel_conf patched=0
  local -a panel_confs=(
    /etc/nginx/sites-available/panel-naive-hy2
    /etc/nginx/conf.d/nhm-panel-8081.conf
    /etc/nginx/conf.d/panel-naive-hy2.conf
  )
  while IFS= read -r panel_conf; do
    [[ -n "$panel_conf" ]] && panel_confs+=("$panel_conf")
  done < <(grep -rl 'proxy_pass http://127\.0\.0\.1:3000' /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null || true)

  while IFS= read -r panel_conf; do
    [[ -f "$panel_conf" ]] || continue
    grep -q 'proxy_pass http://127\.0\.0\.1:3000' "$panel_conf" || grep -q 'proxy_pass http://127.0.0.1:3000' "$panel_conf" || continue
    if ! grep -q 'include /etc/nginx/snippets/nh-subscriptions.conf;' "$panel_conf"; then
      sed -i '/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{/i\    include /etc/nginx/snippets/nh-subscriptions.conf;' "$panel_conf"
    fi
    patched=1
  done < <(printf '%s\n' "${panel_confs[@]}" | sort -u)

  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<'EOF'
server {
    listen 127.0.0.1:18081;
    server_name _;
    include /etc/nginx/snippets/nh-subscriptions.conf;
}
EOF
  fi

  if [[ "$patched" == "1" ]] && nginx -T 2>/dev/null | grep -q 'include /etc/nginx/snippets/nh-subscriptions.conf'; then
    ok "nginx subscription location is configured"
  else
    warn "nginx snippet was written, but no public server includes it. Files are still available locally in ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  fi
  nginx -t >/dev/null && systemctl reload nginx 2>/dev/null || warn "nginx reload failed"
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
  nh_generate
fi
XUI_STARTED_FOR_COMBINED=0
if [[ "$CREATE_XUI" == "1" && "$RELOAD_SERVICES" == "1" && "$XUI_STOPPED_FOR_DB_UPDATE" == "1" ]] && command_exists systemctl; then
  info "Starting x-ui before combined subscription generation"
  xui_cleanup_unix_sockets
  if systemctl start x-ui; then
    sleep 2
    XUI_STARTED_FOR_COMBINED=1
    XUI_STOPPED_FOR_DB_UPDATE=0
  else
    warn "x-ui start failed before combined subscription generation; using database fallback"
  fi
fi
if [[ "$CREATE_XUI" == "1" || "$CREATE_NH" == "1" || "$COMBINED_ONLY" == "1" ]]; then
  combined_generate
fi

if [[ "$RELOAD_SERVICES" == "1" ]]; then
  info "Reloading services"
  if [[ "$CREATE_XUI" == "1" && "$XUI_STARTED_FOR_COMBINED" != "1" ]] && command_exists systemctl; then
    [[ "$XUI_STOPPED_FOR_DB_UPDATE" == "1" ]] || systemctl stop x-ui 2>/dev/null || true
    xui_cleanup_unix_sockets
    systemctl start x-ui || warn "x-ui start failed"
  fi
  if [[ "$CREATE_NH" == "1" ]] && command_exists systemctl; then
    if systemctl is-active --quiet caddy-nh 2>/dev/null; then
      systemctl reload caddy-nh 2>/dev/null || systemctl restart caddy-nh || warn "caddy-nh reload failed"
    fi
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
      systemctl restart hysteria-server || warn "hysteria-server restart failed"
    fi
    if systemctl is-active --quiet panel-naive-hy2 2>/dev/null; then
      systemctl restart panel-naive-hy2 || warn "panel-naive-hy2 restart failed"
    fi
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

if [[ "$CREATE_NH" == "1" ]]; then
  cat <<EOF
NHM:
  NaiveProxy profiles: ${COUNT}
  Hysteria2 profiles: ${COUNT}
  links: /opt/panel-naive-hy2/generated-profiles.txt
  random profile map: ${NH_PROFILE_MAP}
  subscriptions: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}
  combined x-ui+NHM: random per-client names from ${NH_PROFILE_MAP}
  combined all: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}/combined.txt
EOF
elif [[ "$COMBINED_ONLY" == "1" ]]; then
  cat <<EOF
Combined subscriptions:
  random profile map: ${NH_PROFILE_MAP}
  combined all: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}/combined.txt
EOF
fi

cat <<EOF
Backup:
  ${backup_dir}
EOF
