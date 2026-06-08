#!/bin/bash
#################### x-ui-pro v2.4.3 @ github.com/GFW4Fun ##############################################
[[ $EUID -ne 0 ]] && echo "not root! Run with sudo or as root." && exit 1
##############################INFO######################################################################
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}
echo;msg_inf '           ___'	;
msg_inf		 ' \/ __ | |  | '	;
msg_inf		 ' /\    |_| _|_'	; echo
##################################Variables#############################################################
XUIDB="/etc/x-ui/x-ui.db";domain="";UNINSTALL="x";INSTALL="n";PNLNUM=1;CFALLOW="n";CLASH=0;CUSTOMWEBSUB=0
XUI_PROFILE_COUNT="${XUI_PROFILE_COUNT:-15}"
XUI_PROFILE_PREFIX="${XUI_PROFILE_PREFIX:-auto}"
XUI_COMMON_SUB_ID="${XUI_COMMON_SUB_ID:-first}"
XUI_SUB_ID_MODE="${XUI_SUB_ID_MODE:-per-client}"
XUI_SEED_PROFILES="${XUI_SEED_PROFILES:-0}"
XUI_CREATE_DIRECT_CLIENTS="${XUI_CREATE_DIRECT_CLIENTS:-1}"
XUI_CREATE_WARP_INBOUNDS="${XUI_CREATE_WARP_INBOUNDS:-0}"
XUI_WARP_INBOUNDS_ENABLE="${XUI_WARP_INBOUNDS_ENABLE:-0}"
XUI_ENABLE_WARP_ROUTING="${XUI_ENABLE_WARP_ROUTING:-0}"
XUI_AUTO_INSTALL_WARP="${XUI_AUTO_INSTALL_WARP:-0}"
XUI_PRINT_ACCESS_INFO="${XUI_PRINT_ACCESS_INFO:-1}"
XUI_PRO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPM_ROOT_DIR="${UPM_PROJECT_DIR:-}"
[[ -n "$UPM_ROOT_DIR" ]] || UPM_ROOT_DIR="$(cd "${XUI_PRO_SCRIPT_DIR}/../.." 2>/dev/null && pwd || echo "")"
# shellcheck disable=SC1091
source "${UPM_ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${UPM_ROOT_DIR}/lib/warp.sh"
# shellcheck disable=SC1091
source "${UPM_ROOT_DIR}/lib/xui-routing.sh"
# shellcheck disable=SC1091
source "${UPM_ROOT_DIR}/lib/fake-site.sh"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-generated}"
WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}"
XUI_APPLY_WARP_TEMPLATE="${XUI_APPLY_WARP_TEMPLATE:-0}"
XUI_VERSION="${XUI_VERSION-v2.9.4}"
XUI_TARBALL_SHA256="${XUI_TARBALL_SHA256:-}"
if [[ "$XUI_CREATE_DIRECT_CLIENTS" != "1" ]]; then
  XUI_CREATE_DIRECT_CLIENTS=1
fi
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

verify_sha256_if_set() {
  local file="$1" expected="$2"
  [[ -n "$expected" ]] || return 0
  echo "${expected}  ${file}" | sha256sum -c - >/dev/null
}

cleanup_existing() {
  confirm_destructive "x-ui-pro cleanup_existing (removes x-ui and nginx site state)"
  systemctl stop x-ui 2>/dev/null || true
  rm -rf /etc/systemd/system/x-ui.service
  rm -rf /usr/local/x-ui
  rm -rf /etc/x-ui
  rm -rf /etc/nginx/sites-enabled/*
  rm -rf /etc/nginx/sites-available/*
  rm -rf /etc/nginx/stream-enabled/*
}

##################################generate ports and paths#############################################################
get_port() {
	echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && ${#1} -le 253 ]]
}

validate_option_index() {
  local name="$1" value="$2" max="$3"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value > max )); then
    msg_err "Invalid -${name}: expected 0..${max}" && exit 1
  fi
}

xui_uuid() {
  /usr/local/x-ui/bin/xray-linux-amd64 uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

xui_next_free_port() {
  local candidate="$1"
  [[ "$candidate" =~ ^[0-9]+$ && "$candidate" -gt 0 ]] || { printf '0\n'; return 0; }
  while [[ "$(sqlite3 -readonly "$XUIDB" "SELECT COUNT(*) FROM inbounds WHERE port=$candidate;" 2>/dev/null || echo 0)" != "0" ]]; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

xui_profile_label() {
  local inbound_id="$1" protocol="$2" stream_settings network security
  stream_settings="$(sqlite3 -readonly "$XUIDB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
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

xui_client_email() {
  local index="$1" mode="$2" label="$3"
  if [[ "$mode" == "direct" || "$mode" == "standard" ]]; then
    printf '%s-%s-%s\n' "$XUI_PROFILE_PREFIX" "$index" "$label"
  else
    printf '%s-%s-%s-%s\n' "$XUI_PROFILE_PREFIX" "$index" "$mode" "$label"
  fi
}

xui_profile_indices() {
  local total="$1" width i
  width="${#total}"
  [[ "$width" -lt 2 ]] && width=2
  for ((i = 1; i <= total; i++)); do
    printf "%0${width}d\n" "$i"
  done
}

xui_bulk_client_json() {
  local inbound_id="$1" protocol="$2" email="$3" sub_id="$4" now="$5" existing_json="${6:-{}}" password uid client_json is_reality network
  if [[ -z "$existing_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$existing_json"; then
    existing_json="{}"
  fi
  is_reality=0
  if sqlite3 "$XUIDB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" | grep -q '"security"[[:space:]]*:[[:space:]]*"reality"'; then
    is_reality=1
  fi
  network="$(sqlite3 -readonly "$XUIDB" "SELECT COALESCE(json_extract(stream_settings,'$.network'),'tcp') FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || printf 'tcp')"
  if [[ "$protocol" == "trojan" ]]; then
    password="$(gen_random_string 20)"
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
    password="$(gen_random_string 24)"
    jq -cn \
      --arg email "$email" \
      --arg subId "$sub_id" \
      --arg auth "$password" \
      --argjson old "$existing_json" \
      '($old // {}) as $o
      | {auth:($o.auth // $auth),email:$email,enable:($o.enable // true),subId:$subId}'
  else
    uid="$(xui_uuid | tr -d '[:space:]')"
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

xui_enable_preset_xhttp() {
  [[ -f "$XUIDB" ]] || return 0
  sqlite3 "$XUIDB" "
    UPDATE inbounds
    SET enable=1
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp';
  "
}

xui_fix_all_vless_decryption() {
  [[ -f "$XUIDB" ]] || return 0
  sqlite3 "$XUIDB" "
    UPDATE inbounds
    SET settings=json_set(settings, '$.decryption', 'none')
    WHERE protocol='vless'
      AND json_valid(settings);
  "
}

xui_validate_inbound_json() {
  [[ -f "$XUIDB" ]] || return 0
  local bad missing
  bad="$(sqlite3 -readonly "$XUIDB" "
    SELECT id || ' tag=' || COALESCE(tag,'') || ' protocol=' || COALESCE(protocol,'') || ' invalid-json'
    FROM inbounds
    WHERE json_valid(settings)=0
       OR json_valid(stream_settings)=0
       OR json_valid(sniffing)=0;
  " 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    printf '%s\n' "$bad" >&2
    msg_err "x-ui database has malformed inbound JSON; restore backup or regenerate inbounds before restart" && exit 1
  fi

  missing="$(sqlite3 -readonly "$XUIDB" "
    SELECT id || ' tag=' || COALESCE(tag,'') || ' missing-decryption'
    FROM inbounds
    WHERE protocol='vless'
      AND json_valid(settings)=1
      AND COALESCE(json_extract(settings,'$.decryption'),'') != 'none';
  " 2>/dev/null || true)"
  if [[ -n "$missing" ]]; then
    printf '%s\n' "$missing" >&2
    msg_err "x-ui VLESS settings missing decryption=none after repair" && exit 1
  fi
}

xui_post_update_db() {
  xui_repair_invalid_inbound_json
  xui_clear_trojan_client_flows
  xui_repair_shadowsocks_2022_keys
  xui_remove_deprecated_vmess_presets
  xui_disable_experimental_trojan_grpc_presets
  xui_sanitize_inbound_tags
  xui_enable_preset_xhttp
  xui_normalize_xhttp_tcp_inbounds
  xui_restore_reference_vless_grpc_reality_inbounds
  xui_normalize_reference_preset_external_proxy_ports
  xui_ensure_nginx_dynamic_proxy
  xui_ensure_nginx_reality_sni_routes
  xui_enable_preset_domain_sniffing
  xui_fix_all_vless_decryption
  xui_validate_inbound_json
}

xui_set_inbound_clients() {
  local inbound_id="$1" protocol="$2" mode="$3" tag="$4" now index label email sub_id client_json clients_json settings new_settings traffic_result existing_json first_auth
  now="$(date +%s)000"
  clients_json="[]"
  label="$(xui_profile_label "$inbound_id" "$protocol")"
  settings="$(sqlite3 -readonly "$XUIDB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  for index in $(xui_profile_indices "$XUI_PROFILE_COUNT"); do
    sub_id="${XUI_PROFILE_PREFIX}-${index}"
    email="$(xui_client_email "$index" "$mode" "$label")"
    if [[ "$XUI_SUB_ID_MODE" == "common" ]]; then
      sub_id="$XUI_COMMON_SUB_ID"
    fi
    existing_json="$(jq -c --arg email "$email" '((.clients // []) | map(select((.email // "") == $email)) | .[0]) // {}' <<<"$settings")"
    client_json="$(xui_bulk_client_json "$inbound_id" "$protocol" "$email" "$sub_id" "$now" "$existing_json")"
    if [[ -z "$client_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$client_json"; then
      msg_err "Invalid generated client JSON for inbound=$inbound_id email=$email" && exit 1
    fi
    clients_json="$(jq -c --argjson client "$client_json" '. + [$client]' <<<"$clients_json")"
  done

  new_settings="$(jq -c --argjson clients "$clients_json" '.clients = $clients' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  sqlite3 "$XUIDB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  if [[ "$protocol" == "hysteria" || "$protocol" == "hysteria2" ]]; then
    first_auth="$(jq -r '(.clients // [])[0].auth // ""' <<<"$new_settings")"
    [[ -n "$first_auth" ]] && sqlite3 "$XUIDB" "
      UPDATE inbounds
      SET stream_settings=json_set(stream_settings, '$.hysteriaSettings.auth', $(sql_quote "$first_auth"))
      WHERE id=$inbound_id AND json_valid(stream_settings)=1;
    "
  fi
  sqlite3 "$XUIDB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id;"
  for index in $(xui_profile_indices "$XUI_PROFILE_COUNT"); do
    if [[ "$XUI_SUB_ID_MODE" == "common" ]]; then
      sub_id="$XUI_COMMON_SUB_ID"
    else
      sub_id="${XUI_PROFILE_PREFIX}-${index}"
    fi
    email="$(xui_client_email "$index" "$mode" "$label")"
    traffic_result="$(sqlite3 "$XUIDB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, 1, $(sql_quote "$email"), 0, 0, 0, 0, 0); SELECT changes();" 2>/dev/null || true)"
    if [[ "${traffic_result##*$'\n'}" != "1" ]]; then
      msg_err "x-ui traffic row ignored: inbound=$inbound_id email=$email"
    fi
    printf 'inbound=%s protocol=%s tag=%s mode=%s email=%s subId=%s\n' "$inbound_id" "$protocol" "${tag:-}" "$mode" "$email" "$sub_id" >> /etc/x-ui/generated-clients.txt
  done
}

xui_prune_generated_clients() {
  local inbound_id="$1" protocol="$2" settings new_settings
  settings="$(sqlite3 -readonly "$XUIDB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  new_settings="$(jq -c --arg prefix "$XUI_PROFILE_PREFIX" '
    def generated_client:
      ((.email // "") | tostring) as $email
      | ((.subId // "") | tostring) as $sub
      | ($sub | startswith($prefix + "-"))
        or ($email | startswith($prefix + "-"))
        or ($email | contains("-" + $prefix + "-"));
    .clients = ((.clients // []) | map(select(generated_client | not)))
  ' <<<"$settings" | xui_normalize_inbound_settings "$protocol")"
  sqlite3 "$XUIDB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  sqlite3 "$XUIDB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "${XUI_PROFILE_PREFIX}-[0-9]*");"
  sqlite3 "$XUIDB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND email GLOB $(sql_quote "*-${XUI_PROFILE_PREFIX}-[0-9]*");"
}

xui_seed_default_profiles() {
  local inbound_rows inbound_id protocol tag remark port enable warp_tags_file mirror_row mirror_id mirror_protocol mirror_tag routing_tag
  local old_count old_prefix old_sub_mode old_common_sub_id
  [[ -f "$XUIDB" ]] || return 0

  : > /etc/x-ui/generated-clients.txt
  warp_tags_file="$(mktemp)"
  xui_ensure_warp_mirror_inbounds /etc/x-ui/generated-clients.txt
  inbound_rows="$(sqlite3 -separator $'\t' "$XUIDB" \
    "SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), port, enable
     FROM inbounds
     WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
       AND COALESCE(tag,'') NOT LIKE '%-warp'
       AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql)
     ORDER BY id;")"

  old_count="$XUI_PROFILE_COUNT"
  old_prefix="$XUI_PROFILE_PREFIX"
  old_sub_mode="$XUI_SUB_ID_MODE"
  old_common_sub_id="$XUI_COMMON_SUB_ID"
  XUI_PROFILE_COUNT=1
  XUI_PROFILE_PREFIX=first
  XUI_SUB_ID_MODE=common
  XUI_COMMON_SUB_ID=first

  while IFS=$'\t' read -r inbound_id protocol tag remark port enable; do
    [[ -n "$inbound_id" ]] || continue
    if [[ "$XUI_CREATE_DIRECT_CLIENTS" == "1" ]]; then
      xui_set_inbound_clients "$inbound_id" "$protocol" "direct" "$tag"
      routing_tag="$tag"
      if [[ "$XUI_CREATE_WARP_INBOUNDS" == "1" && -n "$tag" ]]; then
        mirror_row="$(sqlite3 -separator $'\t' "$XUIDB" "SELECT id, protocol, COALESCE(tag,'') FROM inbounds WHERE tag=$(sql_quote "${tag}-warp") LIMIT 1;" 2>/dev/null || true)"
        if [[ -n "$mirror_row" ]]; then
          IFS=$'\t' read -r mirror_id mirror_protocol mirror_tag <<<"$mirror_row"
          xui_set_inbound_clients "$mirror_id" "$mirror_protocol" "warp" "$mirror_tag"
          if [[ "${XUI_WARP_INBOUNDS_ENABLE:-0}" == "1" ]]; then
            routing_tag="$mirror_tag"
          fi
        fi
      fi
      [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && -n "$routing_tag" ]] && printf '%s\n' "$routing_tag" >> "$warp_tags_file"
    fi
  done <<<"$inbound_rows"

  XUI_PROFILE_COUNT="$old_count"
  XUI_PROFILE_PREFIX="$old_prefix"
  XUI_SUB_ID_MODE="$old_sub_mode"
  XUI_COMMON_SUB_ID="$old_common_sub_id"

  if [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    xui_apply_warp_template "$warp_tags_file"
  elif [[ "$XUI_ENABLE_WARP_ROUTING" != "1" && "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    xui_remove_warp_template
  fi
  rm -f "$warp_tags_file"
  msg_ok "x-ui seed: standard clients=${XUI_CREATE_DIRECT_CLIENTS}, WARP mirror inbounds=${XUI_CREATE_WARP_INBOUNDS}, WARP routing=${XUI_ENABLE_WARP_ROUTING}"
}

xui_seed_bulk_profiles() {
  local inbound_rows inbound_id protocol tag remark port enable warp_tags_file mirror_row mirror_id mirror_protocol mirror_tag routing_tag
  [[ -f "$XUIDB" ]] || return 0
  [[ "$XUI_SEED_PROFILES" == "1" ]] || { xui_seed_default_profiles; return 0; }
  [[ "$XUI_PROFILE_COUNT" =~ ^[0-9]+$ && "$XUI_PROFILE_COUNT" -gt 0 ]] || XUI_PROFILE_COUNT=15
  : > /etc/x-ui/generated-clients.txt
  warp_tags_file="$(mktemp)"
  xui_ensure_warp_mirror_inbounds /etc/x-ui/generated-clients.txt
  inbound_rows="$(sqlite3 -separator $'\t' "$XUIDB" \
    "SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), port, enable
     FROM inbounds
     WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
       AND COALESCE(tag,'') NOT LIKE '%-warp'
       AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql)
     ORDER BY id;")"
  while IFS=$'\t' read -r inbound_id protocol tag remark port enable; do
    [[ -n "$inbound_id" ]] || continue
    if [[ "$XUI_CREATE_DIRECT_CLIENTS" == "1" ]]; then
      xui_set_inbound_clients "$inbound_id" "$protocol" "direct" "$tag"
      routing_tag="$tag"
      if [[ "$XUI_CREATE_WARP_INBOUNDS" == "1" && -n "$tag" ]]; then
        mirror_row="$(sqlite3 -separator $'\t' "$XUIDB" "SELECT id, protocol, COALESCE(tag,'') FROM inbounds WHERE tag=$(sql_quote "${tag}-warp") LIMIT 1;" 2>/dev/null || true)"
        if [[ -n "$mirror_row" ]]; then
          IFS=$'\t' read -r mirror_id mirror_protocol mirror_tag <<<"$mirror_row"
          xui_set_inbound_clients "$mirror_id" "$mirror_protocol" "warp" "$mirror_tag"
          if [[ "${XUI_WARP_INBOUNDS_ENABLE:-0}" == "1" ]]; then
            routing_tag="$mirror_tag"
          fi
        fi
      fi
      [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && -n "$routing_tag" ]] && printf '%s\n' "$routing_tag" >> "$warp_tags_file"
    else
      xui_prune_generated_clients "$inbound_id" "$protocol"
    fi
  done <<<"$inbound_rows"
  if [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    xui_apply_warp_template "$warp_tags_file"
  elif [[ "$XUI_ENABLE_WARP_ROUTING" != "1" && "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    xui_remove_warp_template
  fi
  rm -f "$warp_tags_file"
  msg_ok "x-ui seed: ${XUI_PROFILE_COUNT} standard clients per inbound, WARP mirror inbounds=${XUI_CREATE_WARP_INBOUNDS}, WARP routing=${XUI_ENABLE_WARP_ROUTING}, subId mode ${XUI_SUB_ID_MODE}"
}

xui_cleanup_unix_sockets() {
  [[ -f "$XUIDB" ]] || return 0
  sqlite3 -readonly "$XUIDB" "SELECT listen FROM inbounds WHERE listen LIKE '/%';" 2>/dev/null \
    | while IFS= read -r listen_path; do
        [[ -n "$listen_path" ]] || continue
        socket_path="${listen_path%%,*}"
        [[ "$socket_path" == /dev/shm/* || "$socket_path" == /run/* || "$socket_path" == /tmp/* ]] || continue
        rm -f -- "$socket_path" || true
      done
}

xui_install_uds_cleanup_dropin() {
  command -v systemctl >/dev/null 2>&1 || return 0
  [[ -f "$XUIDB" ]] || return 0
  local sockets dropin_dir dropin_file rm_args
  sockets="$(sqlite3 -readonly "$XUIDB" "SELECT DISTINCT substr(listen, 1, instr(listen || ',', ',') - 1) FROM inbounds WHERE listen LIKE '/%' AND json_valid(stream_settings)=1 AND json_extract(stream_settings,'$.network')='xhttp';" 2>/dev/null || true)"
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
  msg_ok "x-ui systemd UDS cleanup installed: $dropin_file"
}

xui_disable_duplicate_xhttp_unix_listeners() {
  [[ -f "$XUIDB" ]] || return 0
  sqlite3 "$XUIDB" "
    UPDATE inbounds
    SET listen=''
    WHERE protocol IN ('vless','trojan')
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
  [[ -f "$XUIDB" ]] || return 0
  local rows inbound_id protocol settings client_rows email enable exact_count email_count
  rows="$(sqlite3 -readonly -separator $'\t' "$XUIDB" "SELECT id, protocol, settings FROM inbounds WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2') AND json_valid(settings)=1;" 2>/dev/null || true)"
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
      exact_count="$(sqlite3 -readonly "$XUIDB" "SELECT COUNT(*) FROM client_traffics WHERE inbound_id=$inbound_id AND email=$(sql_quote "$email");" 2>/dev/null || printf '0')"
      if [[ "$exact_count" == "0" ]]; then
        email_count="$(sqlite3 -readonly "$XUIDB" "SELECT COUNT(*) FROM client_traffics WHERE email=$(sql_quote "$email");" 2>/dev/null || printf '0')"
        if [[ "$email_count" == "1" ]]; then
          sqlite3 "$XUIDB" "UPDATE client_traffics SET inbound_id=$inbound_id, enable=${enable:-1} WHERE email=$(sql_quote "$email");" 2>/dev/null || true
        else
          sqlite3 "$XUIDB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, ${enable:-1}, $(sql_quote "$email"), 0, 0, 0, 0, 0);" 2>/dev/null || true
        fi
      else
        sqlite3 "$XUIDB" "UPDATE client_traffics SET enable=${enable:-1} WHERE inbound_id=$inbound_id AND email=$(sql_quote "$email");" 2>/dev/null || true
      fi
    done <<<"$client_rows"
  done <<<"$rows"
  msg_ok "x-ui client traffic rows repaired"
}
check_free() {
	local port=$1
	nc -z -w 2 127.0.0.1 $port &>/dev/null
	return $?
}

make_port() {
	while true; do
		PORT=$(get_port)
		if ! check_free $PORT; then 
			echo $PORT
			break
		fi
	done
}

sub_port=$(make_port)
panel_port=$(make_port)
web_path=$(gen_random_string 10)
sub2singbox_path=$(gen_random_string 10)
sub_path=$(gen_random_string 10)
json_path="/$(gen_random_string 10)/"
panel_path=$(gen_random_string 10)
ws_port=$(make_port)
trojan_port=$(make_port)
ws_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)
xhttp_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)
AUTODOMAIN="n"

##################################Random Port and Path #################################################
#RNDSTR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c "$(shuf -i 6-12 -n 1)")
#while true; do 
#    PORT=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
#    status="$(nc -z 127.0.0.1 $PORT < /dev/null &>/dev/null; echo $?)"
#    if [ "${status}" != "0" ]; then
#        break
#    fi
#done

################################Get arguments###########################################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    -auto_domain) AUTODOMAIN="$2"; shift 2;;
    -install) INSTALL="$2"; shift 2;;
    -panel) PNLNUM="$2"; shift 2;;
    -subdomain) domain="$2"; shift 2;;
    -reality_domain) reality_domain="$2"; shift 2;;
    -ONLY_CF_IP_ALLOW) CFALLOW="$2"; shift 2;;
    -websub) CUSTOMWEBSUB="$2"; shift 2;;
    -clash) CLASH="$2"; shift 2;;
    -uninstall) UNINSTALL="$2"; shift 2;;
    *) shift 1;;
  esac
done

validate_option_index "websub" "$CUSTOMWEBSUB" 1
validate_option_index "clash" "$CLASH" 3


##############################Uninstall#################################################################
UNINSTALL_XUI(){
	confirm_destructive "x-ui-pro uninstall (removes x-ui and nginx state)"
	printf 'y\n' | x-ui uninstall
	rm -rf "/etc/x-ui/" "/usr/local/x-ui/" "/usr/bin/x-ui/"
	$Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx
	$Pak -y purge nginx nginx-common nginx-core nginx-full python3-certbot-nginx
	$Pak -y autoremove
	$Pak -y autoclean
	rm -rf "/var/www/html/" "/etc/nginx/" "/usr/share/nginx/" 
}
if [[ ${UNINSTALL} == *"y"* ]]; then
	UNINSTALL_XUI	
	clear && msg_ok "Completely Uninstalled!" && exit 1
fi


# --- get public IPv4 early (for auto-domain mode)
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')


if [[ ${AUTODOMAIN} == *"y"* ]]; then
    # panel domain: x.x.x.x.cdn-one.org
    domain="${IP4}.cdn-one.org"

    # reality domain: x-x-x-x.cdn-one.org
    reality_domain="${IP4//./-}.cdn-one.org"
fi


##############################Domain Validations########################################################
while true; do	
	if [[ -n "$domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain (sub.domain.tld): " && read domain 
done

domain=$(echo "$domain" 2>&1 | tr -d '[:space:]' )
is_valid_domain "$domain" || { msg_err "Invalid domain: $domain" && exit 1; }
SubDomain=$(echo "$domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
MainDomain=$(echo "$domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] ; then
	MainDomain=${domain}
fi

while true; do	
	if [[ -n "$reality_domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read reality_domain 
done

reality_domain=$(echo "$reality_domain" 2>&1 | tr -d '[:space:]' )
is_valid_domain "$reality_domain" || { msg_err "Invalid REALITY domain: $reality_domain" && exit 1; }
RealitySubDomain=$(echo "$reality_domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
RealityMainDomain=$(echo "$reality_domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] ; then
	RealityMainDomain=${reality_domain}
fi

###############################Install Packages#########################################################
ufw disable
if [[ ${INSTALL} == *"y"* ]]; then
  cleanup_existing

         version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)

         # Проверяем, является ли версия 20 или 22
        if [[ "$version" == "20" || "$version" == "22" ]]; then
              echo "Версия системы: Ubuntu $version"
        fi

	$Pak -y update

	$Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw nodejs

	systemctl daemon-reload && systemctl enable --now nginx
fi
systemctl stop nginx 2>/dev/null || true
##################################GET SERVER IPv4-6#####################################################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com);
[[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com);
##############################Install SSL###############################################################

resolve_to_ip () {
    local host="$1"
    # get first A-record
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    if ! resolve_to_ip "$domain"; then
        msg_err "Auto-domain $domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
    if ! resolve_to_ip "$reality_domain"; then
        msg_err "Auto-domain $reality_domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
fi


certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	msg_err "$domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	msg_err "$reality_domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi
################################# Access to configs only with cloudflare#################################

###################################Get Installed XUI Port/Path##########################################
if [[ -f $XUIDB ]]; then
	XUIPORT=$(sqlite3 -list $XUIDB 'SELECT "value" FROM settings WHERE "key"="webPort" LIMIT 1;' 2>&1)
	XUIPATH=$(sqlite3 -list $XUIDB 'SELECT "value" FROM settings WHERE "key"="webBasePath" LIMIT 1;' 2>&1)
if [[ $XUIPORT -gt 0 && $XUIPORT != "54321" && $XUIPORT != "2053" ]] && [[ ${#XUIPORT} -gt 4 ]]; then
	RNDSTR=$(echo "$XUIPATH" 2>&1 | tr -d '/')
	PORT=$XUIPORT
	sqlite3 $XUIDB <<EOF
	DELETE FROM "settings" WHERE ( "key"="webCertFile" ) OR ( "key"="webKeyFile" ); 
	INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  "");
	INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile", "");
EOF
fi
fi
#################################Nginx Config###########################################################
mkdir -p /root/cert/${domain}
chmod 755 /root/cert/*

ln -s /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -s /etc/letsencrypt/live/${domain}/privkey.pem /root/cert/${domain}/privkey.pem

mkdir -p /etc/nginx/stream-enabled
cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}      xray;
    ${domain}           www;
    default              xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
    listen          [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF

grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_geoip2_module.so;" /etc/nginx* || sed -i '2s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_geoip2_module.so; /' /etc/nginx/nginx.conf
nginx_enable_stream_include || exit 1
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* ||echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf
cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF


cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
	server_tokens off;
	server_name ${domain};
	listen 7443 ssl http2 proxy_protocol;
	listen [::]:7443 ssl http2 proxy_protocol;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/html/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
	if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|--|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 404 500 501 502 503 504 /internal-server-error.html;
	proxy_intercept_errors on;
	#X-UI Admin Panel
	location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;		
        proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
        location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;		
        proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass https://127.0.0.1:${panel_port};
		break;
	}
	include /etc/nginx/snippets/includes.conf;

}
EOF

cat > "/etc/nginx/snippets/includes.conf" << EOF
  	#sub2sing-box
	location /${sub2singbox_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:8080/;
		}
    # Path to open clash.yaml and generate YAML
    location ~ ^/${web_path}/clashmeta/(.+)$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }
    # web
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }
 	#Subscription Path (simple/encode)
        location /${sub_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /${sub_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /assets/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /assets {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	#Subscription Path (json/fragment)
        location /${json_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
	location /${json_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass https://127.0.0.1:${sub_port};
                break;
        }
        #XHTTP
        location /${xhttp_path} {
          grpc_pass grpc://unix:/dev/shm/uds2023.sock;
          grpc_buffer_size         16k;
          grpc_socket_keepalive    on;
          grpc_read_timeout        1h;
          grpc_send_timeout        1h;
          grpc_set_header Connection         "";
          grpc_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
          grpc_set_header X-Forwarded-Proto  \$scheme;
          grpc_set_header X-Forwarded-Port   \$server_port;
          grpc_set_header Host               \$host;
          grpc_set_header X-Forwarded-Host   \$host;
          }
 	#Xray Config Path
	location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
		if (\$hack = 1) {return 404;}
		client_max_body_size 0;
		client_body_timeout 1d;
		grpc_read_timeout 1d;
		grpc_socket_keepalive on;
		proxy_read_timeout 1d;
		proxy_http_version 1.1;
		proxy_buffering off;
		proxy_request_buffering off;
		proxy_socket_keepalive on;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		#proxy_set_header CF-IPCountry \$http_cf_ipcountry;
		#proxy_set_header CF-IP \$realip_remote_addr;
		if (\$http_content_type ~* "grpc") {
			grpc_pass grpc://127.0.0.1:\$fwdport;
			break;
		}
		if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
			proxy_pass http://127.0.0.1:\$fwdport\$request_uri;
			break;
	        }
		if (\$request_method ~* ^(PUT|POST|GET)\$) {
			proxy_pass http://127.0.0.1:\$fwdport\$request_uri;
			break;
		}
	}
	location / { try_files \$uri \$uri/ /internal-server-error.html; }
EOF

cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
	server_tokens off;
	server_name ${reality_domain};
	listen 9443 ssl http2;
	listen [::]:9443 ssl http2;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/html/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$reality_domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$reality_domain/privkey.pem;
	if (\$host !~* ^(.+\.)?${reality_domain}\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|--|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 404 500 501 502 503 504 /internal-server-error.html;
	proxy_intercept_errors on;
	#X-UI Admin Panel
	location /${panel_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:${panel_port};
		break;
	}
        location /$panel_path {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:${panel_port};
		break;
	}
include /etc/nginx/snippets/includes.conf;
}
EOF
##################################Check Nginx status####################################################
if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
	unlink "/etc/nginx/sites-enabled/default" >/dev/null 2>&1
	rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
	ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
        ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
	ln -s "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/" 2>/dev/null
else
	msg_err "${domain} nginx config not exist!" && exit 1
fi

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
    msg_err "nginx config is not ok!" && exit 1
else
	systemctl start nginx 
fi


##############################generate uri's###########################################################
sub_uri=https://${domain}/${sub_path}/
json_uri=https://${domain}/${web_path}?name=
##############################generate keys###########################################################
shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

########################################Update X-UI Port/Path for first INSTALL#########################
UPDATE_XUIDB(){
if [[ -f $XUIDB ]]; then
        x-ui stop
        output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)

        private_key=$(awk -F': *' 'tolower($1) ~ /^private[ _-]?key$/ {print $2; exit}' <<<"$output")
        public_key=$(awk -F': *' 'tolower($1) ~ /^public[ _-]?key$/ || tolower($1) ~ /publickey/ {print $2; exit}' <<<"$output")
        if [[ -z "$private_key" || -z "$public_key" ]]; then
          printf '%s\n' "$output" >&2
          msg_err "Could not parse xray x25519 key pair" && exit 1
        fi

        client_id=$(/usr/local/x-ui/bin/xray-linux-amd64 uuid)
        client_id2=$(/usr/local/x-ui/bin/xray-linux-amd64 uuid)
        client_id3=$(/usr/local/x-ui/bin/xray-linux-amd64 uuid)
	trojan_pass=$(gen_random_string 10)
        emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/ | jq -r '.flag.emoji')
       	sqlite3 $XUIDB <<EOF
             INSERT INTO "settings" ("key", "value") VALUES ("subPort",  '${sub_port}');
	     INSERT INTO "settings" ("key", "value") VALUES ("subPath",  '/${sub_path}/');
	     INSERT INTO "settings" ("key", "value") VALUES ("subURI",  '${sub_uri}');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonPath",  '${json_path}');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonURI",  '${json_uri}');
		 INSERT INTO "settings" ("key", "value") VALUES ("subClashEnable",  'false');
		 INSERT INTO "settings" ("key", "value") VALUES ("subEnableRouting",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("subEnable",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("webListen",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("webDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile",  '');
      	     INSERT INTO "settings" ("key", "value") VALUES ("sessionMaxAge",  '60');
             INSERT INTO "settings" ("key", "value") VALUES ("pageSize",  '50');
             INSERT INTO "settings" ("key", "value") VALUES ("expireDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("trafficDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("remarkModel",  '-ieo');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotEnable",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotToken",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotProxy",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotAPIServer",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotChatId",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgRunTime",  '@daily');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotBackup",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotLoginNotify",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgCpu",  '80');
             INSERT INTO "settings" ("key", "value") VALUES ("tgLang",  'en-US');
	     INSERT INTO "settings" ("key", "value") VALUES ("timeLocation",  'Europe/Moscow');
             INSERT INTO "settings" ("key", "value") VALUES ("secretEnable",  'false');
	     INSERT INTO "settings" ("key", "value") VALUES ("subDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subCertFile",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("subKeyFile",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subUpdates",  '12');
	     INSERT INTO "settings" ("key", "value") VALUES ("subEncrypt",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("subShowInfo",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonFragment",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonNoises",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonMux",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonRules",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("datepicker",  'gregorian');
             INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','first_1','0','0','0','0','0');
		   INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','firstX','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','firstT','0','0','0','0','0');
             INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} reality',
	     '1',
             '0',
	     '127.0.0.1',
             '8443',
	     'vless',
             '{
	     "clients": [
    {
      "id": "${client_id}",
      "flow": "xtls-rprx-vision",
      "email": "first",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "first",
      "reset": 0,
      "created_at": 1756726925000,
      "updated_at": 1756726925000

    }
  ],
  "decryption": "none",
  "fallbacks": []
}',
	     '{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [
    {
      "forceTls": "same",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": [
      "$reality_domain"
    ],
    "privateKey": "${private_key}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}",
      "${shor[1]}",
      "${shor[2]}",
      "${shor[3]}",
      "${shor[4]}",
      "${shor[5]}",
      "${shor[6]}",
      "${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {
      "type": "none"
    }
  }
}',
             'inbound-8443',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} ws',
	     '1',
             '0',
	     '',
             '${ws_port}',
	     'vless',
             '{
  "clients": [
    {
      "id": "${client_id2}",
      "flow": "",
      "email": "first_1",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "first",
      "reset": 0,
      "created_at": 1756726925000,
      "updated_at": 1756726925000

    }
  ],
  "decryption": "none",
  "fallbacks": []
}','{
  "network": "ws",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "wsSettings": {
    "acceptProxyProtocol": false,
    "path": "/${ws_port}/${ws_path}",
    "host": "${domain}",
    "headers": {}
  }
}',
             'inbound-${ws_port}',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
             '0',
             '${emoji_flag} xhttp',
	     '1',
             '0',
	     '/dev/shm/uds2023.sock,0666',
             '0',
	     'vless',
             '{
  "clients": [
    {
      "id": "${client_id3}",
      "flow": "",
      "email": "firstX",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "first",
      "reset": 0,
	  "created_at": 1756726925000,
      "updated_at": 1756726925000
    }
  ],
  "decryption": "none",
  "fallbacks": []
}','{
  "network": "xhttp",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "xhttpSettings": {
    "path": "/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}',
             'inbound-/dev/shm/uds2023.sock,0666:0|',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
	INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} trojan-grpc',
	     '1',
         '0',
		 '',
		 '${trojan_port}',
		 'trojan',
		 '{
  "clients": [
    {
      "comment": "",
      "created_at": 1756726925000,
      "email": "firstT",
      "enable": true,
      "expiryTime": 0,
      "limitIp": 0,
      "password": "${trojan_pass}",
      "reset": 0,
      "subId": "first",
      "tgId": 0,
      "totalGB": 0,
      "updated_at": 1756726925000
    }
  ],
  "fallbacks": []
}',
'{
  "network": "grpc",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "grpcSettings": {
    "serviceName": "${trojan_port}/${trojan_path}",
    "authority": "${domain}",
    "multiMode": false
  }
}',
'inbound-${trojan_port}',
'{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	);
EOF
xui_install_3dp_reference_presets \
  "$XUIDB" \
  "$domain" \
  "$private_key" \
  "$public_key" \
  "$emoji_flag" \
  "/root/cert/${domain}/fullchain.pem" \
  "/root/cert/${domain}/privkey.pem"
xui_repair_invalid_inbound_json
xui_clear_trojan_client_flows
xui_repair_shadowsocks_2022_keys
xui_remove_deprecated_vmess_presets
xui_disable_experimental_trojan_grpc_presets
xui_sanitize_inbound_tags
xui_normalize_grpc_service_names
xui_restore_reference_vless_grpc_reality_inbounds
xui_normalize_reference_preset_external_proxy_ports
xui_enable_preset_domain_sniffing
xui_ensure_nginx_dynamic_proxy
xui_ensure_nginx_reality_sni_routes
if [[ "$XUI_ENABLE_WARP_ROUTING" == "1" && "$XUI_AUTO_INSTALL_WARP" == "1" ]]; then
  ensure_warp_local_proxy "$UPM_ROOT_DIR"
fi
xui_seed_bulk_profiles
xui_open_warp_reality_ports
xui_repair_client_traffic_rows
xui_disable_duplicate_xhttp_unix_listeners
xui_install_uds_cleanup_dropin
xui_cleanup_unix_sockets
/usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}"
/usr/local/x-ui/x-ui cert -webCert "/root/cert/${domain}/fullchain.pem" -webCertKey "/root/cert/${domain}/privkey.pem"
cat > /etc/x-ui/access-info.env <<EOF
XUI_DOMAIN="${domain}"
XUI_PANEL_URL="https://${domain}:${panel_port}/${panel_path}/"
XUI_PANEL_LOGIN="${config_username}"
XUI_PANEL_PASSWORD="${config_password}"
XUI_PANEL_PORT="${panel_port}"
XUI_PANEL_PATH="/${panel_path}/"
EOF
chmod 600 /etc/x-ui/access-info.env
x-ui start
else
	msg_err "x-ui.db file not exist! Maybe x-ui isn't installed." && exit 1;
fi
}
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

config_after_install() {
            /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"    
            /usr/local/x-ui/x-ui migrate
}

install_panel() {
apt-get update && apt-get install -y -q wget curl tar tzdata
    cd /usr/local/
    
    # Download resources
    if [ $# == 0 ]; then
        if [[ -n "$XUI_VERSION" ]]; then
            tag_version="$XUI_VERSION"
        else
            tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        fi
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
                exit 1
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
        if ! verify_sha256_if_set "/usr/local/x-ui-linux-$(arch).tar.gz" "$XUI_TARBALL_SHA256"; then
            echo -e "${red}Downloaded x-ui archive SHA256 mismatch${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"
        
        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi
        
        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
        if ! verify_sha256_if_set "/usr/local/x-ui-linux-$(arch).tar.gz" "$XUI_TARBALL_SHA256"; then
            echo -e "${red}Downloaded x-ui archive SHA256 mismatch${plain}"
            exit 1
        fi
    fi
    wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui.sh${plain}"
        exit 1
    fi
    
    # Stop x-ui service and remove old resources
    if [[ -e /usr/local/x-ui/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm /usr/local/x-ui/ -rf
    fi
    
    # Extract resources and set permissions
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f
    
    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh
    
    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)
    
    # Update x-ui cli and se set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
	config_after_install
    
    if [[ $release == "alpine" ]]; then
        wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
        systemctl daemon-reload
        systemctl enable x-ui
        systemctl start x-ui
    fi
    
    echo -e "${green}x-ui ${tag_version}${plain} installation finished, it is running now..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"

}
###################################Install X-UI#########################################################
if [[ ${INSTALL} == *"y"* ]]; then
	install_panel
	UPDATE_XUIDB
	xui_post_update_db
	if ! systemctl is-enabled --quiet x-ui; then
		systemctl daemon-reload && systemctl enable x-ui.service
	fi
	x-ui restart
elif systemctl is-active --quiet x-ui; then
	xui_post_update_db
	x-ui restart
else
    install_panel	
	UPDATE_XUIDB
	xui_post_update_db
	if ! systemctl is-enabled --quiet x-ui; then
		systemctl daemon-reload && systemctl enable x-ui.service
	fi
	x-ui restart
fi

######################enable bbr and tune system########################################################
apt-get install -yqq --no-install-recommends ca-certificates
cat > /etc/sysctl.d/99-upm-xui-network.conf << 'SYSCTLEOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=2097152
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.somaxconn=8192
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.ipv4.ip_no_pmtu_disc=0
net.ipv4.icmp_echo_ignore_all=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTLEOF

sysctl --system
sysctl -p /etc/sysctl.d/99-upm-xui-network.conf


######################install_sub2sing-box#################################################################

if pgrep -x "sub2sing-box" > /dev/null; then
    echo "kill sub2sing-box..."
    pkill -x "sub2sing-box"
fi
if [ -f "/usr/bin/sub2sing-box" ]; then
    echo "delete sub2sing-box..."
    rm -f /usr/bin/sub2sing-box
fi
wget -P /root/ https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz
tar -xvzf /root/sub2sing-box_0.0.9_linux_amd64.tar.gz -C /root/ --strip-components=1 sub2sing-box_0.0.9_linux_amd64/sub2sing-box
mv /root/sub2sing-box /usr/bin/
chmod +x /usr/bin/sub2sing-box
rm /root/sub2sing-box_0.0.9_linux_amd64.tar.gz
su -c "/usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 & disown" root

######################install_fake_site#################################################################

upm_install_fake_site /var/www/html

######################install_web_sub_page##############################################################

URL_SUB_PAGE=( "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui.html"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui-classical.html"
	)
URL_CLASH_SUB=( "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash.yaml"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_skrepysh.yaml"
		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_fullproxy_without_ru.yaml"
  		"https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_refilter_ech.yaml"
	)
DEST_DIR_SUB_PAGE="/var/www/subpage"
DEST_FILE_SUB_PAGE="$DEST_DIR_SUB_PAGE/index.html"
DEST_FILE_CLASH_SUB="$DEST_DIR_SUB_PAGE/clash.yaml"

sudo mkdir -p "$DEST_DIR_SUB_PAGE"

sudo curl -L "${URL_CLASH_SUB[$CLASH]}" -o "$DEST_FILE_CLASH_SUB"
sudo curl -L "${URL_SUB_PAGE[$CUSTOMWEBSUB]}" -o "$DEST_FILE_SUB_PAGE"

sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_SUB_PAGE"
sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_CLASH_SUB"
sed -i "s#\${SUB_JSON_PATH}#$json_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_CLASH_SUB"
sed -i "s|sub.legiz.ru|$domain/$sub2singbox_path|g" "$DEST_FILE_SUB_PAGE"

#while true; do	
#	if [[ -n "$tg_escaped_link" ]]; then
#		break
#	fi
#	echo -en "Enter your support link for web sub page (example https://t.me/durov/ ): " && read tg_escaped_link
#done

#sed -i -e "s|https://t.me/gozargah_marzban|$tg_escaped_link|g" -e "s|https://github.com/Gozargah/Marzban#donation|$tg_escaped_link|g" "$DEST_FILE_SUB_PAGE"

######################cronjob for ssl/reload service/cloudflareips######################################
(crontab -l 2>/dev/null || true) | grep -v "certbot\|x-ui\|cloudflareips\|sub2sing-box" | crontab -
(crontab -l 2>/dev/null; echo '@reboot /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1') | crontab -
(crontab -l 2>/dev/null; echo '@daily x-ui restart > /dev/null 2>&1 && nginx -s reload;') | crontab -
(crontab -l 2>/dev/null; echo '@monthly certbot renew --nginx --non-interactive --post-hook "nginx -s reload" > /dev/null 2>&1;') | crontab -
##################################ufw###################################################################
ufw disable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "${panel_port}/tcp"
ufw allow "${sub_port}/tcp"
xui_open_public_preset_ports
ufw --force enable  
##################################Show Details##########################################################

if [[ "$XUI_PRINT_ACCESS_INFO" == "1" ]]; then
	if systemctl is-active --quiet x-ui; then clear
		printf '0\n' | x-ui | grep --color=never -i ':'
		msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
		nginx -T | grep -i 'ssl_certificate\|ssl_certificate_key'
		msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
		certbot certificates | grep -i 'Path:\|Domains:\|Expiry Date:'

#	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
#	if [[ -n $IP4 ]] && [[ "$IP4" =~ $IP4_REGEX ]]; then 
#		msg_inf "IPv4: http://$IP4:$PORT/$RNDSTR/"
#	fi
#	if [[ -n $IP6 ]] && [[ "$IP6" =~ $IP6_REGEX ]]; then 
#		msg_inf "IPv6: http://[$IP6]:$PORT/$RNDSTR/"
#	fi

		msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
		msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
		echo -e "Username:  ${config_username} \n"
		echo -e "Password:  ${config_password} \n"
		msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
		if [[ "$XUI_SEED_PROFILES" == "1" ]]; then
			msg_inf "Web Sub Page subscriptions: https://${domain}/${web_path}?name=${XUI_PROFILE_PREFIX}-01 ... ${XUI_PROFILE_PREFIX}-${XUI_PROFILE_COUNT}\n"
		else
			msg_inf "Web Sub Page subscription: https://${domain}/${web_path}?name=first\n"
		fi
		msg_inf "Your local sub2sing-box instance: https://${domain}/$sub2singbox_path/\n"
		msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
		msg_inf "Please Save this Screen!!"
	else
		nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
		msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
	fi
else
	if systemctl is-active --quiet x-ui; then
		msg_ok "x-ui installed. Final access summary will be printed by unified installer."
	else
		nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
		msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
	fi
fi
#################################################N-joy##################################################
