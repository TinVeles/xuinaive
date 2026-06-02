#!/usr/bin/env bash

xui_v3_db_path() {
  printf '%s\n' "${XUI_DB:-/etc/x-ui/x-ui.db}"
}

xui_v3_require_schema() {
  local db="${1:-$(xui_v3_db_path)}" table
  [[ -f "$db" ]] || upm_die "x-ui database not found: $db"
  for table in inbounds clients client_inbounds client_traffics; do
    [[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$(sql_quote "$table");")" == "1" ]] \
      || upm_die "x-ui v3 table is missing: $table. Install the latest panel line first."
  done
}

xui_v3_uuid() {
  local xray_binary
  xray_binary="$(xui_v3_xray_binary || true)"
  if [[ -n "$xray_binary" ]]; then
    "$xray_binary" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

xui_v3_xray_binary() {
  local arch binary
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) arch="" ;;
  esac

  if [[ -n "$arch" ]]; then
    binary="/usr/local/x-ui/bin/xray-linux-$arch"
    [[ -x "$binary" ]] && printf '%s\n' "$binary" && return 0
  fi
  command -v xray 2>/dev/null || return 1
}

xui_v3_profile_indices() {
  local total="$1" width i
  width="${#total}"
  [[ "$width" -lt 2 ]] && width=2
  for ((i = 1; i <= total; i++)); do
    printf "%0${width}d\n" "$i"
  done
}

xui_v3_selected_inbounds() {
  local db="${1:-$(xui_v3_db_path)}"
  sqlite3 -readonly -separator $'\t' "$db" "
    SELECT id,
           protocol,
           COALESCE(json_extract(stream_settings, '$.network'), 'tcp'),
           COALESCE(json_extract(stream_settings, '$.security'), 'none')
    FROM inbounds
    WHERE enable=1
      AND protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
      AND json_valid(settings)=1
      AND json_valid(stream_settings)=1
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql)
    ORDER BY id;
  "
}

xui_v3_remove_generated_json_clients() {
  local db="$1" inbound_id="$2" prefix="$3" settings new_settings
  settings="$(sqlite3 -readonly "$db" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  new_settings="$(jq -c --arg prefix "$prefix" '
    .clients = [
      (.clients // [])[]
      | select((((.email // "") | tostring) | startswith($prefix + "-")) | not)
    ]
  ' <<<"$settings")"
  sqlite3 "$db" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
}

xui_v3_client_json() {
  local db="$1" client_id="$2" flow_override="$3"
  sqlite3 -readonly "$db" "
    SELECT json_object(
      'id', uuid,
      'security', security,
      'password', password,
      'flow', $(sql_quote "$flow_override"),
      'auth', auth,
      'email', email,
      'limitIp', limit_ip,
      'totalGB', total_gb,
      'expiryTime', expiry_time,
      'enable', json(CASE WHEN enable=0 THEN 'false' ELSE 'true' END),
      'tgId', tg_id,
      'subId', sub_id,
      'group', group_name,
      'comment', comment,
      'reset', reset,
      'created_at', created_at,
      'updated_at', updated_at
    )
    FROM clients
    WHERE id=$client_id;
  "
}

xui_v3_append_json_client() {
  local db="$1" inbound_id="$2" client_json="$3" settings new_settings email
  settings="$(sqlite3 -readonly "$db" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  email="$(jq -r '.email // empty' <<<"$client_json")"
  [[ -n "$email" ]] || upm_die "Cannot append x-ui v3 JSON client without email"
  if jq -e --arg email "$email" '
    any((.clients // [])[]; (((.email // "") | tostring) == $email))
  ' <<<"$settings" >/dev/null; then
    return 0
  fi
  new_settings="$(jq -c --argjson client "$client_json" '
    .clients = ((.clients // []) + [$client])
  ' <<<"$settings")"
  sqlite3 "$db" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
}

xui_v3_restore_attached_json_clients() {
  local db="$1" inbound_id client_id flow_override client_json
  while IFS=$'\t' read -r inbound_id client_id flow_override; do
    [[ -n "$inbound_id" && -n "$client_id" ]] || continue
    flow_override="${flow_override//$'\r'/}"
    client_json="$(xui_v3_client_json "$db" "$client_id" "$flow_override")"
    [[ -n "$client_json" ]] || continue
    xui_v3_append_json_client "$db" "$inbound_id" "$client_json"
  done < <(sqlite3 -readonly -separator $'\t' "$db" "
    SELECT ci.inbound_id, ci.client_id, COALESCE(ci.flow_override, '')
    FROM client_inbounds ci
    JOIN clients c ON c.id=ci.client_id
    JOIN inbounds i ON i.id=ci.inbound_id
    WHERE json_valid(i.settings)=1
    ORDER BY ci.inbound_id, ci.client_id;
  ")
}

xui_v3_remove_orphan_client_traffics() {
  local db="$1" removed
  removed="$(sqlite3 "$db" "
    DELETE FROM client_traffics
    WHERE NOT EXISTS (
      SELECT 1 FROM clients c WHERE c.email=client_traffics.email
    )
      AND NOT EXISTS (
        SELECT 1
        FROM inbounds i,
             json_each(
               CASE WHEN json_valid(i.settings)=1 THEN i.settings ELSE '{\"clients\":[]}' END,
               '$.clients'
             ) j
        WHERE json_extract(j.value, '$.email')=client_traffics.email
      );
    SELECT changes();
  ")"
  if [[ "$removed" =~ ^[0-9]+$ && "$removed" -gt 0 ]]; then
    printf 'INFO: Removed orphaned x-ui v3 traffic row(s): %s\n' "$removed"
  fi
}

xui_v3_replace_generated_clients() {
  local db="${1:-$(xui_v3_db_path)}" count="$2" prefix="$3" report_file="$4"
  local rows index email sub_id uuid password auth client_id first_inbound_id="" desired_clients=""
  local inbound_id protocol network security flow_override client_json now

  xui_v3_require_schema "$db"
  XUI_DB="$db" xui_clear_trojan_client_flows
  XUI_DB="$db" xui_repair_shadowsocks_2022_keys
  rows="$(xui_v3_selected_inbounds "$db")"
  [[ -n "$rows" ]] || upm_die "No enabled x-ui preset inbounds found in $db"
  now="$(date +%s)000"

  for index in $(xui_v3_profile_indices "$count"); do
    email="${prefix}-${index}"
    [[ -z "$desired_clients" ]] || desired_clients+=","
    desired_clients+="$(sql_quote "$email")"
  done

  sqlite3 "$db" "
    DELETE FROM client_inbounds
    WHERE client_id IN (SELECT id FROM clients WHERE email GLOB $(sql_quote "${prefix}-[0-9]*"));
    DELETE FROM client_traffics
    WHERE email GLOB $(sql_quote "${prefix}-[0-9]*")
      AND email NOT IN ($desired_clients);
    DELETE FROM clients
    WHERE email GLOB $(sql_quote "${prefix}-[0-9]*")
      AND email NOT IN ($desired_clients);
  "
  : > "$report_file"

  while IFS=$'\t' read -r inbound_id protocol network security; do
    [[ -n "$inbound_id" ]] || continue
    XUI_DB="$db" xui_v3_remove_generated_json_clients "$db" "$inbound_id" "$prefix"
  done <<<"$rows"

  for index in $(xui_v3_profile_indices "$count"); do
    email="${prefix}-${index}"
    sub_id="$email"
    client_id="$(sqlite3 -readonly "$db" "SELECT id FROM clients WHERE email=$(sql_quote "$email") LIMIT 1;")"
    if [[ -z "$client_id" ]]; then
      uuid="$(xui_v3_uuid | tr -d '[:space:]')"
      password="$(openssl rand -base64 32 | tr -d '\r\n')"
      auth="$(openssl rand -hex 16 | tr -d '\r\n')"
      client_id="$(sqlite3 "$db" "
        INSERT INTO clients
          (email, sub_id, uuid, password, auth, flow, security, reverse, limit_ip, total_gb, expiry_time, enable, tg_id, group_name, comment, reset, created_at, updated_at)
        VALUES
          ($(sql_quote "$email"), $(sql_quote "$sub_id"), $(sql_quote "$uuid"), $(sql_quote "$password"), $(sql_quote "$auth"), '', 'auto', '', 0, 0, 0, 1, 0, '', '', 0, $now, $now);
        SELECT last_insert_rowid();
      ")"
    fi

    while IFS=$'\t' read -r inbound_id protocol network security; do
      [[ -n "$inbound_id" ]] || continue
      protocol="${protocol//$'\r'/}"
      network="${network//$'\r'/}"
      security="${security//$'\r'/}"
      [[ -n "$first_inbound_id" ]] || first_inbound_id="$inbound_id"
      flow_override=""
      if [[ "$protocol" == "vless" && "$network" == "tcp" && "$security" == "reality" ]]; then
        flow_override="xtls-rprx-vision"
      fi
      sqlite3 "$db" "
        INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
        VALUES ($client_id, $inbound_id, $(sql_quote "$flow_override"), $now);
      "
      client_json="$(xui_v3_client_json "$db" "$client_id" "$flow_override")"
      [[ -n "$client_json" ]] || upm_die "Generated x-ui v3 client record is missing: id=$client_id"
      xui_v3_append_json_client "$db" "$inbound_id" "$client_json"
      printf 'client=%s subId=%s inbound=%s protocol=%s network=%s flow=%s\n' \
        "$email" "$sub_id" "$inbound_id" "$protocol" "$network" "$flow_override" >> "$report_file"
    done <<<"$rows"

    sqlite3 "$db" "
      INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
      VALUES (${first_inbound_id:-0}, 1, $(sql_quote "$email"), 0, 0, 0, 0, 0);
    "
  done

  xui_v3_restore_attached_json_clients "$db"
  xui_v3_remove_orphan_client_traffics "$db"
}
