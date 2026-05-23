#!/usr/bin/env bash

xui_db_path() {
  printf '%s\n' "${XUI_DB:-${XUIDB:-/etc/x-ui/x-ui.db}}"
}

xui_preset_inbound_filter_sql() {
  cat <<'SQL'
       AND (
         (protocol='vless'
          AND json_valid(stream_settings)=1
          AND json_extract(stream_settings,'$.network')='tcp'
          AND json_extract(stream_settings,'$.security')='reality')
         OR (protocol='vless'
             AND json_valid(stream_settings)=1
             AND json_extract(stream_settings,'$.network') IN ('ws','xhttp'))
         OR (protocol='trojan'
             AND json_valid(stream_settings)=1
             AND json_extract(stream_settings,'$.network')='grpc')
       )
SQL
}

xui_enable_preset_domain_sniffing() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  sqlite3 "$db" "
    UPDATE inbounds
    SET sniffing='{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}'
    WHERE protocol IN ('vless','trojan')
$(xui_preset_inbound_filter_sql)
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
  "
}

xui_enable_warp_domain_sniffing() {
  xui_enable_preset_domain_sniffing
}

xui_delete_warp_clone_inbounds() {
  local db deleted
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  deleted="$(sqlite3 "$db" "
    DELETE FROM client_traffics
    WHERE inbound_id IN (
      SELECT id FROM inbounds
      WHERE (
        COALESCE(tag,'') LIKE '%-warp'
        OR lower(COALESCE(remark,'')) LIKE '%warp%'
      )
    );
    DELETE FROM inbounds
    WHERE (
      COALESCE(tag,'') LIKE '%-warp'
      OR lower(COALESCE(remark,'')) LIKE '%warp%'
    );
    SELECT changes();
  " 2>/dev/null || true)"
  deleted="${deleted##*$'\n'}"
  if [[ -n "$deleted" && "$deleted" != "0" ]]; then
    upm_log_ok "Deleted legacy WARP clone inbounds: $deleted"
  fi
}

xui_apply_warp_template() {
  local warp_tags_file="$1"
  local db tags_json domains_json current key keys snippet_file updated updated_count
  db="$(xui_db_path)"
  if [[ ! -s "$warp_tags_file" ]]; then
    xui_remove_warp_template
    return 0
  fi
  tags_json="$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$warp_tags_file")"
  domains_json="$(warp_domains_json "${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}")"
  snippet_file="/etc/x-ui/warp-generated-routing.json"
  warp_write_xray_snippet "$snippet_file" "${WARP_OUTBOUND_TAG:-warp-cli}" "${WARP_PROXY_HOST:-127.0.0.1}" "${WARP_PROXY_PORT:-40000}" "${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}" "$(jq -r 'join(",")' <<<"$tags_json")"

  if [[ "${XUI_APPLY_WARP_TEMPLATE:-1}" != "1" ]]; then
    upm_log_ok "WARP routing snippet saved: $snippet_file"
    return 0
  fi

  keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key IN ('xrayTemplateConfig','xrayConfig','xraySetting') ORDER BY CASE key WHEN 'xrayTemplateConfig' THEN 0 ELSE 1 END;" || true)"
  [[ -n "$keys" ]] || keys="xrayTemplateConfig"
  updated_count=0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    current="$(sqlite3 -readonly "$db" "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" || true)"
    [[ -n "$current" ]] || current='{}'
    if ! jq -e . >/dev/null 2>&1 <<<"$current"; then
      upm_log_warn "x-ui setting $key is not valid JSON. Skipping this key; snippet remains saved: $snippet_file"
      continue
    fi

    updated="$(jq -c \
      --arg tag "${WARP_OUTBOUND_TAG:-warp-cli}" \
      --arg host "${WARP_PROXY_HOST:-127.0.0.1}" \
      --argjson port "${WARP_PROXY_PORT:-40000}" \
      --argjson inboundTags "$tags_json" \
      --argjson domains "$domains_json" '
      def outbound_or($tag; $default):
        ((.outbounds // []) | map(select(.tag == $tag)) | .[0]) // $default;
      def warp_outbound($tag; $host; $port):
        {tag:$tag, protocol:"socks", settings:{servers:[{address:$host, port:$port, users:[]}]}};
      def rule_marker($rule):
        ($rule.outboundTag // "") + "|" +
        (($rule.inboundTag // []) | tostring) + "|" +
        (($rule.domain // []) | tostring) + "|" +
        (($rule.ip // []) | tostring) + "|" +
        (($rule.protocol // []) | tostring);
      def merge_rules($base; $add):
        ($base + $add)
        | reduce .[] as $r ([]; if any(.[]; rule_marker(.) == rule_marker($r)) then . else . + [$r] end);

      . as $root
      | .outbounds = (
          [
            ($root | outbound_or("direct"; {tag:"direct", protocol:"freedom"})),
            warp_outbound($tag; $host; $port),
            ($root | outbound_or("blocked"; {tag:"blocked", protocol:"blackhole"}))
          ]
          + (($root.outbounds // []) | map(select(.tag != "direct" and .tag != "blocked" and .tag != $tag)))
        )
      | .routing = (.routing // {})
      | .routing.rules = merge_rules(
          ((.routing.rules // []) | map(select(.outboundTag != $tag)));
          [
            {type:"field", inboundTag:$inboundTags, domain:$domains, outboundTag:$tag},
            {type:"field", inboundTag:["api"], outboundTag:"api"},
            {type:"field", ip:["geoip:private"], outboundTag:"blocked"},
            {type:"field", protocol:["bittorrent"], outboundTag:"blocked"},
            {type:"field", domain:["geosite:category-ru"], outboundTag:"direct"},
            {type:"field", ip:["geoip:ru"], outboundTag:"direct"}
          ]
        )
    ' <<<"$current")"

    sqlite3 "$db" "DELETE FROM settings WHERE key=$(sql_quote "$key");"
    sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$updated"));"
    updated_count=$((updated_count + 1))
  done <<<"$keys"
  if [[ "$updated_count" -gt 0 ]]; then
    upm_log_ok "x-ui WARP SOCKS outbound/routing saved in $updated_count settings key(s)"
  else
    upm_log_warn "No valid x-ui settings key was updated; WARP routing snippet saved only: $snippet_file"
  fi
  upm_log_ok "WARP routing snippet saved: $snippet_file"
}

xui_remove_warp_template() {
  local db key keys current updated snippet_file updated_count
  db="$(xui_db_path)"
  snippet_file="/etc/x-ui/warp-generated-routing.json"
  [[ -f "$db" ]] || return 0
  keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key IN ('xrayTemplateConfig','xrayConfig','xraySetting');" || true)"
  [[ -n "$keys" ]] || return 0
  updated_count=0
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    current="$(sqlite3 -readonly "$db" "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" || true)"
    [[ -n "$current" ]] || continue
    if ! jq -e . >/dev/null 2>&1 <<<"$current"; then
      upm_log_warn "x-ui setting $key is not valid JSON; WARP template cleanup skipped for this key"
      continue
    fi
    updated="$(jq -c --arg tag "${WARP_OUTBOUND_TAG:-warp-cli}" '
      .outbounds = ((.outbounds // []) | map(select(.tag != $tag)))
      | .routing = (.routing // {})
      | .routing.rules = ((.routing.rules // []) | map(select(.outboundTag != $tag)))
      | if (.outbounds | length) == 0 then del(.outbounds) else . end
      | if ((.routing.rules? // []) | length) == 0 then del(.routing.rules) else . end
      | if ((.routing? // {}) | length) == 0 then del(.routing) else . end
    ' <<<"$current")"
    sqlite3 "$db" "DELETE FROM settings WHERE key=$(sql_quote "$key");"
    sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$updated"));"
    updated_count=$((updated_count + 1))
  done <<<"$keys"
  rm -f "$snippet_file" 2>/dev/null || true
  upm_log_ok "x-ui WARP outbound/routing removed from $updated_count settings key(s)"
}
