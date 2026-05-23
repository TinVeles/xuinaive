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

xui_apply_warp_template() {
  local warp_tags_file="$1"
  local db tags_json domains_json current key keys snippet_file updated updated_count inbound_spec snippet_inbound_tags key_exists
  db="$(xui_db_path)"
  inbound_spec="${WARP_INBOUND_TAG:-all}"
  if [[ ! -s "$warp_tags_file" && "$inbound_spec" != "all" && "$inbound_spec" != "*" && "$inbound_spec" != "" ]]; then
    [[ "${XUI_APPLY_WARP_TEMPLATE:-0}" == "1" ]] && xui_remove_warp_template
    return 0
  fi
  if [[ "$inbound_spec" == "all" || "$inbound_spec" == "*" || "$inbound_spec" == "" ]]; then
    tags_json="null"
    snippet_inbound_tags="all"
  elif [[ "$inbound_spec" == "generated" || "$inbound_spec" == "preset" ]]; then
    tags_json="$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$warp_tags_file")"
    snippet_inbound_tags="$(jq -r 'join(",")' <<<"$tags_json")"
  else
    tags_json="$(printf '%s\n' "$inbound_spec" | tr ',' '\n' | jq -Rsc 'split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
    snippet_inbound_tags="$inbound_spec"
  fi
  domains_json="$(warp_domains_json "${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}")"
  snippet_file="/etc/x-ui/warp-generated-routing.json"
  warp_write_xray_snippet "$snippet_file" "${WARP_OUTBOUND_TAG:-warp-cli}" "${WARP_PROXY_HOST:-127.0.0.1}" "${WARP_PROXY_PORT:-40000}" "${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}" "$snippet_inbound_tags"

  if [[ "${XUI_APPLY_WARP_TEMPLATE:-0}" != "1" ]]; then
    upm_log_ok "WARP routing snippet saved: $snippet_file"
    return 0
  fi

  keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" || true)"
  if [[ -z "$keys" ]]; then
    keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key IN ('xrayConfig','xraySetting') ORDER BY CASE key WHEN 'xrayConfig' THEN 0 ELSE 1 END LIMIT 1;" || true)"
  fi
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
      '
      def warp_outbound($tag; $host; $port):
        {tag:$tag, protocol:"socks", settings:{servers:[{address:$host, port:$port, users:[]}]}};

      .outbounds = (
        (.outbounds // [])
        | if any(.[]?; .tag == "direct") then . else . + [{tag:"direct", protocol:"freedom"}] end
        | if any(.[]?; .tag == "blocked") then . else . + [{tag:"blocked", protocol:"blackhole"}] end
        | if any(.[]?; .tag == $tag)
          then map(if .tag == $tag then warp_outbound($tag; $host; $port) else . end)
          else . + [warp_outbound($tag; $host; $port)]
          end
      )
    ' <<<"$current")"

    key_exists="$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM settings WHERE key=$(sql_quote "$key");" || printf '0')"
    if [[ "$key_exists" -gt 0 ]]; then
      sqlite3 "$db" "UPDATE settings SET value=$(sql_quote "$updated") WHERE key=$(sql_quote "$key");"
    else
      sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$updated"));"
    fi

    current="$updated"
    updated="$(jq -c \
      --arg tag "${WARP_OUTBOUND_TAG:-warp-cli}" \
      --argjson inboundTags "$tags_json" \
      --argjson domains "$domains_json" '
      def rule_marker($rule):
        ($rule.outboundTag // "") + "|" +
        (($rule.inboundTag // []) | tostring) + "|" +
        (($rule.domain // []) | tostring) + "|" +
        (($rule.ip // []) | tostring) + "|" +
        (($rule.protocol // []) | tostring);
      def merge_rules($base; $add):
        ($base + $add)
        | reduce .[] as $r ([]; if any(.[]; rule_marker(.) == rule_marker($r)) then . else . + [$r] end);
      def warp_rule($domains; $inboundTags; $tag):
        ({type:"field", domain:$domains, outboundTag:$tag}
        + (if $inboundTags == null then {} else {inboundTag:$inboundTags} end));

      .routing = (.routing // {})
      | .routing.rules = merge_rules(
          (.routing.rules // []);
          [
            {type:"field", inboundTag:["api"], outboundTag:"api"},
            {type:"field", ip:["geoip:private"], outboundTag:"blocked"},
            {type:"field", protocol:["bittorrent"], outboundTag:"blocked"}
          ]
        )
      | .routing.rules = (
          (.routing.rules // [])
          | if any(.[]?; .outboundTag == $tag)
            then map(if .outboundTag == $tag then warp_rule($domains; $inboundTags; $tag) else . end)
            else . + [warp_rule($domains; $inboundTags; $tag)]
            end
        )
    ' <<<"$current")"

    sqlite3 "$db" "UPDATE settings SET value=$(sql_quote "$updated") WHERE key=$(sql_quote "$key");"
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
  keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;" || true)"
  if [[ -z "$keys" ]]; then
    keys="$(sqlite3 -readonly "$db" "SELECT key FROM settings WHERE key IN ('xrayConfig','xraySetting') ORDER BY CASE key WHEN 'xrayConfig' THEN 0 ELSE 1 END LIMIT 1;" || true)"
  fi
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
      def missing_outbound($tag):
        any((.outbounds // [])[]?; .tag == $tag) | not;
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
          (($root.outbounds // []) | map(select(.tag != $tag)))
          + (if ($root | missing_outbound("direct")) then [{tag:"direct", protocol:"freedom"}] else [] end)
          + (if ($root | missing_outbound("blocked")) then [{tag:"blocked", protocol:"blackhole"}] else [] end)
        )
      | .routing = (.routing // {})
      | .routing.rules = merge_rules(
          ((.routing.rules // []) | map(select(.outboundTag != $tag)));
          [
            {type:"field", inboundTag:["api"], outboundTag:"api"},
            {type:"field", ip:["geoip:private"], outboundTag:"blocked"},
            {type:"field", protocol:["bittorrent"], outboundTag:"blocked"}
          ]
        )
      | if (.outbounds | length) == 0 then del(.outbounds) else . end
      | if ((.routing.rules? // []) | length) == 0 then del(.routing.rules) else . end
      | if ((.routing? // {}) | length) == 0 then del(.routing) else . end
    ' <<<"$current")"
    sqlite3 "$db" "UPDATE settings SET value=$(sql_quote "$updated") WHERE key=$(sql_quote "$key");"
    updated_count=$((updated_count + 1))
  done <<<"$keys"
  rm -f "$snippet_file" 2>/dev/null || true
  upm_log_ok "x-ui WARP outbound/routing removed from $updated_count settings key(s)"
}
