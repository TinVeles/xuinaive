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
NH_SUBSCRIPTION_DIR="${NH_SUBSCRIPTION_DIR:-/opt/panel-naive-hy2/subscriptions}"
NH_SUBSCRIPTION_TOKEN_FILE="${NH_SUBSCRIPTION_TOKEN_FILE:-/etc/nh-panel/subscription-token}"
NH_SUBSCRIPTION_NGINX="${NH_SUBSCRIPTION_NGINX:-1}"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-all}"
WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}"
XUI_APPLY_WARP_TEMPLATE="${XUI_APPLY_WARP_TEMPLATE:-0}"
XUI_INBOUND_ID="${XUI_INBOUND_ID:-}"
XUI_COMMON_SUB_ID="${XUI_COMMON_SUB_ID:-$PREFIX}"
XUI_SUB_ID_MODE="${XUI_SUB_ID_MODE:-per-client}"
XUI_CREATE_DIRECT="${XUI_CREATE_DIRECT:-1}"
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
  disabled by default; enable routing with --xui-warp-routing or install+route with --install-warp.
  generated clients use standard preset inbounds by default.
  AI-domain WARP routing is written to /etc/x-ui/warp-generated-routing.json when enabled.
  auto-installs Cloudflare WARP local proxy only with --install-warp or --auto-install-warp.
  use --apply-xui-warp-template to also write warp-cli outbound/rules into x-ui settings.
  use --cleanup-xui-warp-template to remove previously written warp-cli outbound/rules.

x-ui selection:
  default: every preset vless/trojan inbound
  --xui-inbound-id ID: only one inbound
  default subId mode: per-client (auto-01 contains all protocol variants for auto-01)
  --xui-sub-id-mode common: one subscription contains all generated clients
  default replace mode: selected inbound clients become exactly COUNT
  --xui-keep-existing: keep existing non-generated clients
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
if [[ "$XUI_CREATE_DIRECT" != "1" ]]; then
  warn "Standard clients are disabled; enabling them because clone inbounds are no longer supported."
  XUI_CREATE_DIRECT=1
fi

for cmd in node openssl; do
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
for path in "$XUI_DB" "$NH_CONFIG" "$CADDYFILE" "$HYSTERIA_CONFIG" /etc/nginx/snippets/nh-subscriptions.conf; do
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
  stream_settings="$(sqlite3 -readonly "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
  network="$(jq -r '.network // "tcp"' <<<"$stream_settings" 2>/dev/null || echo "tcp")"
  security="$(jq -r '.security // "none"' <<<"$stream_settings" 2>/dev/null || echo "none")"
  if [[ "$security" == "reality" ]]; then
    printf 'reality\n'
  elif [[ "$protocol" == "trojan" && "$network" == "grpc" ]]; then
    printf 'trojan-grpc\n'
  elif [[ -n "$network" && "$network" != "null" ]]; then
    printf '%s\n' "$network" | tr -cd 'A-Za-z0-9_.-'
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

xui_table_exists() {
  local table="$1"
  [[ -f "$XUI_DB" ]] || return 1
  [[ "$(sqlite3 -readonly "$XUI_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$(sql_quote "$table");" 2>/dev/null || printf '0')" == "1" ]]
}

xui_has_client_tables() {
  xui_table_exists clients && xui_table_exists client_inbounds
}

xui_strip_reality_label() {
  local email="$1"
  email="${email#reality-}"
  email="${email%-reality}"
  printf '%s\n' "$email"
}

xui_reality_client_base() {
  local sub_id="$1" email base
  if xui_has_client_tables; then
    email="$(sqlite3 -readonly "$XUI_DB" "
      SELECT c.email
      FROM clients c
      JOIN client_inbounds ci ON ci.client_id = c.id
      JOIN inbounds i ON i.id = ci.inbound_id
      WHERE i.enable=1
        AND i.protocol='vless'
        AND json_valid(i.stream_settings)=1
        AND json_extract(i.stream_settings,'$.security')='reality'
        AND c.sub_id=$(sql_quote "$sub_id")
        AND c.enable=1
      ORDER BY i.id, c.id
      LIMIT 1;
    " 2>/dev/null || true)"
  fi
  [[ -n "${email:-}" ]] || \
  email="$(sqlite3 -readonly "$XUI_DB" "
    SELECT settings
    FROM inbounds
    WHERE enable=1
      AND protocol='vless'
      AND json_valid(settings)=1
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.security')='reality'
    ORDER BY id;
  " 2>/dev/null | jq -r --arg sub_id "$sub_id" '
    (.clients // [])[]
    | select((.enable // true) != false)
    | select((.subId // "") == $sub_id)
    | (.email // "")
    | select(. != "")
  ' 2>/dev/null | head -n 1)"
  base="$(xui_strip_reality_label "$email")"
  [[ -n "$base" ]] || base="$sub_id"
  printf '%s\n' "$base"
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
  local inbound_id="$1" protocol="$2" email="$3" sub_id="$4" now="$5" existing_json="${6:-{}}" password uid client_json is_reality
  if [[ -z "$existing_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$existing_json"; then
    existing_json="{}"
  fi
  is_reality=0
  if sqlite3 "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" | grep -q '"security"[[:space:]]*:[[:space:]]*"reality"'; then
    is_reality=1
  fi
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
    if [[ "$is_reality" == "1" ]]; then
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

xui_sync_client_tables() {
  local inbound_id="$1" clients_json="$2" report_file="$3" detach_scope="${4:-$XUI_REPLACE_CLIENTS}"
  local old_client_ids client_rows email sub_id uuid password auth flow security limit_ip total_gb expiry_time enable tg_id comment reset created_at updated_at client_id
  xui_has_client_tables || return 0

  if [[ "$detach_scope" == "1" || "$detach_scope" == "all" ]]; then
    old_client_ids="$(sqlite3 -readonly "$XUI_DB" "SELECT client_id FROM client_inbounds WHERE inbound_id=$inbound_id;" 2>/dev/null || true)"
    sqlite3 "$XUI_DB" "DELETE FROM client_inbounds WHERE inbound_id=$inbound_id;" 2>/dev/null || true
  else
    old_client_ids="$(sqlite3 -readonly "$XUI_DB" "
      SELECT ci.client_id
      FROM client_inbounds ci
      JOIN clients c ON c.id = ci.client_id
      WHERE ci.inbound_id=$inbound_id
        AND (c.sub_id GLOB $(sql_quote "${PREFIX}-[0-9]*") OR c.email GLOB $(sql_quote "${PREFIX}-[0-9]*"));
    " 2>/dev/null || true)"
    sqlite3 "$XUI_DB" "
      DELETE FROM client_inbounds
      WHERE inbound_id=$inbound_id
        AND client_id IN (
          SELECT id FROM clients
          WHERE sub_id GLOB $(sql_quote "${PREFIX}-[0-9]*")
             OR email GLOB $(sql_quote "${PREFIX}-[0-9]*")
        );
    " 2>/dev/null || true
  fi

  while IFS= read -r client_id; do
    [[ -n "$client_id" ]] || continue
    sqlite3 "$XUI_DB" "DELETE FROM clients WHERE id=$client_id AND NOT EXISTS (SELECT 1 FROM client_inbounds WHERE client_id=$client_id);" 2>/dev/null || true
  done <<<"$old_client_ids"

  client_rows="$(jq -r '
    def text(v): (v // "" | tostring);
    def num(v): (v // 0 | tostring | if . == "" then "0" else . end);
    .[]
    | [
        text(.email),
        text(.subId),
        text(.id),
        text(.password),
        text(.auth),
        text(.flow),
        text(.security),
        num(.limitIp),
        num(.totalGB),
        num(.expiryTime),
        (if (.enable // true) then "1" else "0" end),
        num(.tgId),
        text(.comment),
        num(.reset),
        num(.created_at),
        num(.updated_at)
      ]
    | @tsv
  ' <<<"$clients_json" 2>/dev/null || true)"

  while IFS=$'\t' read -r email sub_id uuid password auth flow security limit_ip total_gb expiry_time enable tg_id comment reset created_at updated_at; do
    [[ -n "$email" ]] || continue
    [[ -n "$created_at" && "$created_at" != "0" ]] || created_at="$(date +%s)000"
    [[ -n "$updated_at" && "$updated_at" != "0" ]] || updated_at="$created_at"
    [[ -n "$enable" ]] || enable=1
    [[ -n "$limit_ip" ]] || limit_ip=0
    [[ -n "$total_gb" ]] || total_gb=0
    [[ -n "$expiry_time" ]] || expiry_time=0
    [[ -n "$tg_id" ]] || tg_id=0
    [[ -n "$reset" ]] || reset=0

    sqlite3 "$XUI_DB" "
      INSERT OR IGNORE INTO clients
        (email, sub_id, uuid, password, auth, flow, security, reverse, limit_ip, total_gb, expiry_time, enable, tg_id, comment, reset, created_at, updated_at)
      VALUES
        ($(sql_quote "$email"), $(sql_quote "$sub_id"), $(sql_quote "$uuid"), $(sql_quote "$password"), $(sql_quote "$auth"), $(sql_quote "$flow"), $(sql_quote "$security"), '', $limit_ip, $total_gb, $expiry_time, $enable, $tg_id, $(sql_quote "$comment"), $reset, $created_at, $updated_at);
      UPDATE clients
      SET sub_id=$(sql_quote "$sub_id"),
          uuid=$(sql_quote "$uuid"),
          password=$(sql_quote "$password"),
          auth=$(sql_quote "$auth"),
          flow=$(sql_quote "$flow"),
          security=$(sql_quote "$security"),
          limit_ip=$limit_ip,
          total_gb=$total_gb,
          expiry_time=$expiry_time,
          enable=$enable,
          tg_id=$tg_id,
          comment=$(sql_quote "$comment"),
          reset=$reset,
          updated_at=$updated_at
      WHERE email=$(sql_quote "$email");
    " 2>/dev/null || {
      printf 'WARN clients-table sync failed inbound=%s email=%s\n' "$inbound_id" "$email" >> "$report_file"
      continue
    }

    client_id="$(sqlite3 -readonly "$XUI_DB" "SELECT id FROM clients WHERE email=$(sql_quote "$email") LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$client_id" ]] || continue
    sqlite3 "$XUI_DB" "
      INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
      VALUES ($client_id, $inbound_id, $(sql_quote "$flow"), $created_at);
      UPDATE client_inbounds
      SET flow_override=$(sql_quote "$flow")
      WHERE client_id=$client_id AND inbound_id=$inbound_id;
    " 2>/dev/null || printf 'WARN client_inbounds sync failed inbound=%s email=%s\n' "$inbound_id" "$email" >> "$report_file"
  done <<<"$client_rows"
}

xui_repair_invalid_inbound_settings() {
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET settings = CASE
      WHEN protocol='vless' THEN '{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}'
      WHEN protocol='trojan' THEN '{\"clients\":[],\"fallbacks\":[]}'
      ELSE settings
    END
    WHERE protocol IN ('vless','trojan')
      AND json_valid(settings)=0;
  "
}

xui_repair_invalid_inbound_json() {
  xui_repair_invalid_inbound_settings
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET sniffing='{\"enabled\":false,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}'
    WHERE sniffing IS NULL
       OR sniffing=''
       OR json_valid(sniffing)=0;

    UPDATE inbounds
    SET stream_settings='{\"network\":\"tcp\",\"security\":\"none\"}'
    WHERE stream_settings IS NULL
       OR stream_settings=''
       OR json_valid(stream_settings)=0;
  "
}

xui_sanitize_inbound_tags() {
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET tag = 'inbound-' ||
      CASE
        WHEN port IS NOT NULL AND port > 0 THEN port
        ELSE id
      END
    WHERE tag IS NULL
       OR tag = ''
       OR tag LIKE '%/%'
       OR tag LIKE '%,%'
       OR tag LIKE '%:%'
       OR tag LIKE '%|%'
       OR tag LIKE '% %';
  "
}

xui_enable_preset_xhttp() {
  sqlite3 "$XUI_DB" "
    UPDATE inbounds
    SET enable=1
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp';
  "
}

xui_replace_generated_clients() {
  local inbound_id="$1" protocol="$2" mode="$3" tag="$4" report_file="$5"
  local now index label email sub_id base client_json clients_json settings new_settings traffic_result existing_json
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
    existing_json="$(jq -c --arg email "$email" '((.clients // []) | map(select((.email // "") == $email)) | .[0]) // {}' <<<"$settings")"
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
      def generated_email:
        ((.email // "") | tostring) as $email
        | ((.subId // "") | tostring) as $subId
        | (($email | startswith($prefix + "-")) or ($subId | startswith($prefix + "-")));
      .clients = ((.clients // [])
        | map(select(generated_email | not))
        + $clients)
    ' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  fi

  sqlite3 "$XUI_DB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  xui_sync_client_tables "$inbound_id" "$clients_json" "$report_file" "$XUI_REPLACE_CLIENTS"
  if [[ "$XUI_REPLACE_CLIENTS" == "1" ]]; then
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id;"
  else
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "${PREFIX}-[0-9]*");"
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
  settings="$(sqlite3 -readonly "$XUI_DB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  new_settings="$(jq -c --arg prefix "$PREFIX" '
    def generated_email:
      ((.email // "") | tostring) as $email
      | ((.subId // "") | tostring) as $subId
      | (($email | startswith($prefix + "-")) or ($subId | startswith($prefix + "-")));
    .clients = ((.clients // []) | map(select(generated_email | not)))
  ' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  sqlite3 "$XUI_DB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  xui_sync_client_tables "$inbound_id" "[]" "$report_file" "generated"
  sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "${PREFIX}-[0-9]*");"
  printf 'inbound=%s mode=direct action=pruned-generated prefix=%s\n' "$inbound_id" "$PREFIX" >> "$report_file"
}

xui_add_clients() {
  info "Creating x-ui clients in $XUI_DB"
  local inbound_rows inbound_id protocol tag remark port enable report_file warp_tags_file query
  report_file="/etc/x-ui/generated-clients.txt"
  warp_tags_file="$(mktemp)"
  mkdir -p "$(dirname "$report_file")"
  : > "$report_file"
  xui_repair_invalid_inbound_json
  xui_sanitize_inbound_tags
  xui_enable_preset_xhttp
  xui_enable_preset_domain_sniffing

  query="SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), port, enable
     FROM inbounds
     WHERE protocol IN ('vless','trojan')
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
      [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && -n "$tag" ]] && printf '%s\n' "$tag" >> "$warp_tags_file"
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
  rows="$(sqlite3 -readonly -separator $'\t' "$XUI_DB" "SELECT id, protocol, settings FROM inbounds WHERE protocol IN ('vless','trojan') AND json_valid(settings)=1;" 2>/dev/null || true)"
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
  if xui_has_client_tables; then
    rows="$(sqlite3 -readonly -separator $'\t' "$XUI_DB" "
      SELECT ci.inbound_id, c.email, COALESCE(c.enable, 1)
      FROM clients c
      JOIN client_inbounds ci ON ci.client_id = c.id
      WHERE COALESCE(c.email, '') != '';
    " 2>/dev/null || true)"
    while IFS=$'\t' read -r inbound_id email enable; do
      [[ -n "$inbound_id" && -n "$email" ]] || continue
      sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, ${enable:-1}, $(sql_quote "$email"), 0, 0, 0, 0, 0);" 2>/dev/null || true
      sqlite3 "$XUI_DB" "UPDATE client_traffics SET enable=${enable:-1} WHERE email=$(sql_quote "$email");" 2>/dev/null || true
    done <<<"$rows"
  fi
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
    printf '%s\n' "$NH_SUBSCRIPTION_TOKEN" > "$NH_SUBSCRIPTION_TOKEN_FILE"
    chmod 0600 "$NH_SUBSCRIPTION_TOKEN_FILE"
  fi
  [[ -n "$NH_SUBSCRIPTION_TOKEN" ]] || die "Could not create NHM subscription token"
  chmod 0600 "$NH_SUBSCRIPTION_TOKEN_FILE" 2>/dev/null || true

  COUNT="$COUNT" PREFIX="$PREFIX" NH_CONFIG="$NH_CONFIG" CADDYFILE="$CADDYFILE" HYSTERIA_CONFIG="$HYSTERIA_CONFIG" NH_SUBSCRIPTION_DIR="$NH_SUBSCRIPTION_DIR" NH_SUBSCRIPTION_TOKEN="$NH_SUBSCRIPTION_TOKEN" SCRIPT_DIR="$SCRIPT_DIR" node <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const path = require('path');

const count = parseInt(process.env.COUNT || '4', 10);
const prefix = process.env.PREFIX || 'auto';
const cfgPath = process.env.NH_CONFIG;
const caddyfile = process.env.CADDYFILE;
const hyPath = process.env.HYSTERIA_CONFIG;
const reportPath = '/opt/panel-naive-hy2/generated-profiles.txt';
const subRoot = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const subToken = process.env.NH_SUBSCRIPTION_TOKEN || 'missing-token';
const subDir = path.join(subRoot, subToken);

function pass() {
  return cp.execSync("openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20", { encoding: 'utf8', shell: '/bin/bash' }).trim();
}

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
const generatedNaiveRe = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-naive-[0-9]+$`);
const generatedHy2Re = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-hy2-[0-9]+$`);
const existingGeneratedNaive = new Map(
  cfg.naiveUsers
    .filter(u => generatedNaiveRe.test(String(u.username || '')))
    .map(u => [String(u.username), u])
);
const existingGeneratedHy2 = new Map(
  cfg.hy2Users
    .filter(u => generatedHy2Re.test(String(u.username || '')))
    .map(u => [String(u.username), u])
);

cfg.naiveUsers = cfg.naiveUsers.filter(u => !generatedNaiveRe.test(String(u.username || '')));
cfg.hy2Users = cfg.hy2Users.filter(u => !generatedHy2Re.test(String(u.username || '')));

for (let i = 1; i <= count; i += 1) {
  const n = String(i).padStart(2, '0');
  const naiveName = `${prefix}-naive-${n}`;
  const hyName = `${prefix}-hy2-${n}`;
  const oldNaive = existingGeneratedNaive.get(naiveName) || {};
  const oldHy = existingGeneratedHy2.get(hyName) || {};
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
const generatedNaiveLinks = generatedNaive.map(u => `naive+https://${u.username}:${u.password}@${domain}:443#${encodeURIComponent(u.username)}`);
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

  COUNT="$COUNT" PREFIX="$PREFIX" XUI_DB="$XUI_DB" NH_CONFIG="$NH_CONFIG" NH_SUBSCRIPTION_DIR="$NH_SUBSCRIPTION_DIR" NH_SUBSCRIPTION_TOKEN="$NH_SUBSCRIPTION_TOKEN" node <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const path = require('path');

const count = parseInt(process.env.COUNT || '4', 10);
const prefix = process.env.PREFIX || 'auto';
const xuiDb = process.env.XUI_DB;
const nhConfig = process.env.NH_CONFIG;
const subRoot = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const subToken = process.env.NH_SUBSCRIPTION_TOKEN || '';
const subDir = path.join(subRoot, subToken);

function b64(s) {
  return Buffer.from(s, 'utf8').toString('base64');
}

function encode(v) {
  return encodeURIComponent(String(v ?? ''));
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
  return clients.filter(c => c && c.enable !== false && c.enable !== 0 && c.enable !== '0' && String(c.subId || '') === wantedSubId);
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
    params.set('security', 'reality');
    addParam(params, 'pbk', settings.publicKey);
    addParam(params, 'fp', settings.fingerprint || 'chrome');
    addParam(params, 'sni', serverNames[0] || settings.serverName);
    addParam(params, 'sid', Array.isArray(reality.shortIds) ? reality.shortIds[0] : '');
    addParam(params, 'spx', settings.spiderX || '/');
    addParam(params, 'flow', client.flow);
  } else {
    params.set('security', ep.tls === 'tls' || ep.tls === 'same' || [443, 8443].includes(ep.port) ? 'tls' : security);
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
  const params = new URLSearchParams();
  params.set('type', network);
  params.set('security', ep.tls === 'tls' || ep.tls === 'same' || [443, 8443].includes(ep.port) ? 'tls' : String(stream.security || 'none'));

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

function isStableV2rayNLink(row) {
  try {
    const stream = JSON.parse(row.stream_settings || '{}');
    const network = String(stream.network || 'tcp');
    const security = String(stream.security || 'none');
    return network === 'ws' || network === 'grpc' || (network === 'tcp' && security === 'reality');
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
        AND protocol IN ('vless','trojan')
        AND json_valid(settings)=1
        AND json_valid(stream_settings)=1
      ORDER BY id
    );
  `;
  const out = cp.execFileSync('sqlite3', ['-readonly', xuiDb, sql], { encoding: 'utf8' });
  return JSON.parse(out || '[]');
}

function tableExists(name) {
  try {
    const out = cp.execFileSync('sqlite3', ['-readonly', xuiDb, `SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${String(name).replace(/'/g, "''")}';`], { encoding: 'utf8' });
    return String(out || '').trim() === '1';
  } catch (_) {
    return false;
  }
}

function clientsByInbound() {
  if (!tableExists('clients') || !tableExists('client_inbounds')) return new Map();
  const sql = `
    SELECT COALESCE(json_group_array(json_object(
      'inbound_id', inbound_id,
      'email', email,
      'subId', COALESCE(sub_id, ''),
      'id', COALESCE(uuid, ''),
      'password', COALESCE(password, ''),
      'auth', COALESCE(auth, ''),
      'flow', COALESCE(NULLIF(flow_override, ''), flow, ''),
      'security', COALESCE(security, ''),
      'limitIp', COALESCE(limit_ip, 0),
      'totalGB', COALESCE(total_gb, 0),
      'expiryTime', COALESCE(expiry_time, 0),
      'enable', COALESCE(enable, 1),
      'tgId', COALESCE(tg_id, 0),
      'comment', COALESCE(comment, ''),
      'reset', COALESCE(reset, 0)
    )), '[]')
    FROM (
      SELECT ci.inbound_id, c.email, c.sub_id, c.uuid, c.password, c.auth, c.flow, c.security,
             c.limit_ip, c.total_gb, c.expiry_time, c.enable, c.tg_id, c.comment, c.reset, ci.flow_override, c.id
      FROM clients c
      JOIN client_inbounds ci ON ci.client_id = c.id
      ORDER BY ci.inbound_id, c.id
    );
  `;
  const out = cp.execFileSync('sqlite3', ['-readonly', xuiDb, sql], { encoding: 'utf8' });
  const records = JSON.parse(out || '[]');
  const byInbound = new Map();
  for (const record of records) {
    const inboundId = Number(record.inbound_id || 0);
    if (!inboundId || !record.email) continue;
    const client = { ...record, enable: Number(record.enable) !== 0 };
    delete client.inbound_id;
    if (!byInbound.has(inboundId)) byInbound.set(inboundId, []);
    byInbound.get(inboundId).push(client);
  }
  return byInbound;
}

function mergeTableClients(rows) {
  const byInbound = clientsByInbound();
  if (!byInbound.size) return rows;
  return rows.map(row => {
    const clients = byInbound.get(Number(row.id));
    if (!clients || !clients.length) return row;
    let settings = {};
    try { settings = JSON.parse(row.settings || '{}'); } catch (_) {}
    settings.clients = clients;
    return { ...row, settings: JSON.stringify(settings) };
  });
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
  const hasLinks = /(?:vless|trojan|vmess|ss|hysteria2|hy2):\/\//i.test(text);
  if (hasLinks) return text.split(/\r?\n/).map(s => s.trim()).filter(Boolean).join('\n');
  const compact = text.replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/=_-]+$/.test(compact)) return '';
  try {
    const decoded = Buffer.from(compact.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8').trim();
    if (/(?:vless|trojan|vmess|ss|hysteria2|hy2):\/\//i.test(decoded)) {
      return decoded.split(/\r?\n/).map(s => s.trim()).filter(Boolean).join('\n');
    }
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

function renameXuiLinks(links, subId, realityBases) {
  const baseName = realityBases.get(subId) || subId;
  return links.map(link => renameLinkFragment(link, `${xuiLinkLabel(link)}-${baseName}`));
}

function stripRealityLabel(email) {
  return String(email || '').trim().replace(/^reality-/, '').replace(/-reality$/, '');
}

function xuiRealityBaseBySubId(rows) {
  const bases = new Map();
  const fallback = new Map();
  for (const row of rows) {
    let settings;
    try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
    let stream;
    try { stream = JSON.parse(row.stream_settings || '{}'); } catch (_) { stream = {}; }
    const isReality = String(stream.security || '') === 'reality';
    const clients = Array.isArray(settings.clients) ? settings.clients : [];
    for (const client of clients) {
      if (!client || client.enable === false || client.enable === 0 || client.enable === '0') continue;
      const subId = String(client.subId || '');
      const email = String(client.email || '').trim();
      if (!subId || !email) continue;
      if (!fallback.has(subId)) fallback.set(subId, stripRealityLabel(email));
      if (isReality && !bases.has(subId)) bases.set(subId, stripRealityLabel(email));
    }
  }
  for (const [subId, base] of fallback) {
    if (!bases.has(subId)) bases.set(subId, base);
  }
  return bases;
}

function nhLinksBySubId(realityBases) {
  const cfg = JSON.parse(fs.readFileSync(nhConfig, 'utf8'));
  const domain = cfg.domain || 'DOMAIN_NOT_SET';
  const bySubId = new Map();
  const naive = Array.isArray(cfg.naiveUsers) ? cfg.naiveUsers : [];
  const hy2 = Array.isArray(cfg.hy2Users) ? cfg.hy2Users : [];

  for (let i = 1; i <= count; i += 1) {
    const n = String(i).padStart(2, '0');
    const subId = `${prefix}-${n}`;
    const links = [];
    const nUser = naive.find(u => String(u.username || '') === `${prefix}-naive-${n}`);
    const hUser = hy2.find(u => String(u.username || '') === `${prefix}-hy2-${n}`);
    const baseName = realityBases.get(subId) || subId;
    if (nUser) links.push(`naive+https://${encode(nUser.username)}:${encode(nUser.password)}@${domain}:443#${encode(`naive-${baseName}`)}`);
    if (hUser) links.push(`hysteria2://${encode(hUser.username)}:${encode(hUser.password)}@${domain}:443?sni=${domain}&insecure=0#${encode(`hy2-${baseName}`)}`);
    bySubId.set(subId, links);
  }
  return bySubId;
}

const rows = mergeTableClients(xuiRows());
const realityBases = xuiRealityBaseBySubId(rows);
const bySubId = new Map();
for (let i = 1; i <= count; i += 1) {
  bySubId.set(`${prefix}-${String(i).padStart(2, '0')}`, []);
}

for (const row of rows) {
  let settings;
  try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
  for (const subId of bySubId.keys()) {
    for (const client of firstEnabledClient(settings, subId)) {
      const link = row.protocol === 'trojan' ? trojanLink(row, client) : vlessLink(row, client);
      if (link) bySubId.get(subId).push(link);
    }
  }
}

const nhBySubId = nhLinksBySubId(realityBases);
const combinedAll = [];
const xrayAll = [];
const stableXrayAll = [];
fs.mkdirSync(subDir, { recursive: true, mode: 0o755 });

for (const [subId, links] of bySubId) {
  const officialXuiText = fetchXuiSubscription(subId);
  const officialXuiLinks = officialXuiText ? officialXuiText.split(/\n/).filter(Boolean) : [];
  const xuiLinks = renameXuiLinks(officialXuiLinks.length ? officialXuiLinks : links, subId, realityBases);
  const combined = [...xuiLinks, ...(nhBySubId.get(subId) || [])];
  const text = combined.join('\n');
  const xrayText = xuiLinks.join('\n');
  const stableLinks = [];
  if (officialXuiLinks.length) {
    stableLinks.push(...officialXuiLinks.filter(link => !/[?&]type=xhttp(?:&|$)/i.test(link) && !/[?&]type=splithttp(?:&|$)/i.test(link)));
  } else {
    for (const row of rows) {
      if (!isStableV2rayNLink(row)) continue;
      let settings;
      try { settings = JSON.parse(row.settings || '{}'); } catch (_) { continue; }
      for (const client of firstEnabledClient(settings, subId)) {
        const link = row.protocol === 'trojan' ? trojanLink(row, client) : vlessLink(row, client);
        if (link) stableLinks.push(link);
      }
    }
  }
  const stableText = stableLinks.join('\n');
  fs.writeFileSync(path.join(subDir, `${subId}.txt`), text + (text ? '\n' : ''), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subId}.b64`), b64(text), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subId}-v2rayn.txt`), b64(xrayText) + '\n', { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subId}-v2rayn.b64`), b64(xrayText), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subId}-v2rayn-raw.txt`), xrayText + (xrayText ? '\n' : ''), { mode: 0o644 });
  fs.writeFileSync(path.join(subDir, `${subId}-v2rayn-stable.txt`), b64(stableText) + '\n', { mode: 0o644 });
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
  ok "Combined x-ui + NHM subscriptions saved: ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN/${PREFIX}-01.txt ... ${PREFIX}-${COUNT}.txt"
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

cat <<EOF

Profile generation complete
---------------------------
x-ui:
  standard generated clients: ${XUI_CREATE_DIRECT} (${COUNT} per selected preset inbound when enabled)
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

NHM:
  NaiveProxy profiles: ${COUNT}
  Hysteria2 profiles: ${COUNT}
  links: /opt/panel-naive-hy2/generated-profiles.txt
  subscriptions: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}
  combined x-ui+NHM: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}/${PREFIX}-01.txt ... ${PREFIX}-${COUNT}.txt
  combined all: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}/combined.txt

Backup:
  ${backup_dir}
EOF
