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
    SET sniffing='{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":true}'
    WHERE protocol IN ('vless','trojan')
$(xui_preset_inbound_filter_sql)
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
  "
}

xui_enable_warp_domain_sniffing() {
  xui_enable_preset_domain_sniffing
}

xui_next_free_inbound_port() {
  local db="$1" candidate="$2"
  [[ "$candidate" =~ ^[0-9]+$ && "$candidate" -gt 0 ]] || candidate=30000
  while :; do
    case "$candidate" in
      22|25|53|80|110|143|443|465|587|993|995|2053|2083|2087|2096|3000|54321|7443|8080|8081|8443|9443|9445)
        candidate=$((candidate + 1))
        continue
        ;;
    esac
    if [[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds WHERE port=$candidate;" 2>/dev/null || echo 0)" != "0" ]]; then
      candidate=$((candidate + 1))
      continue
    fi
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$candidate" 2>/dev/null | grep -q .; then
      candidate=$((candidate + 1))
      continue
    fi
    break
  done
  printf '%s\n' "$candidate"
}

xui_normalize_xhttp_tcp_inbounds() {
  local db rows inbound_id port listen stream_settings new_port new_stream
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  rows="$(sqlite3 -separator $'\t' "$db" "
    SELECT id, COALESCE(port,0), COALESCE(listen,''), stream_settings
    FROM inbounds
    WHERE protocol IN ('vless','trojan')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
    ORDER BY id;
  " 2>/dev/null || true)"

  while IFS=$'\t' read -r inbound_id port listen stream_settings; do
    [[ -n "$inbound_id" ]] || continue
    if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$listen" != /* ]]; then
      continue
    fi
    new_port="$(xui_next_free_inbound_port "$db" 30000)"
    new_stream="$(jq -c --argjson oldPort "${port:-0}" --argjson newPort "$new_port" '
      def clean_path($path):
        (($path // "") | tostring) as $p
        | if $p == "" then "xhttp"
          elif ($oldPort > 0 and ($p | startswith("/" + ($oldPort|tostring) + "/"))) then
            ($p | sub("^/" + ($oldPort|tostring) + "/"; ""))
          else
            ($p | sub("^/+"; ""))
          end;
      .xhttpSettings = (.xhttpSettings // {})
      | .xhttpSettings.path = "/" + ($newPort|tostring) + "/" + clean_path(.xhttpSettings.path)
    ' <<<"$stream_settings")"
    sqlite3 "$db" "
      UPDATE inbounds
      SET listen='', port=$new_port, stream_settings=$(sql_quote "$new_stream")
      WHERE id=$inbound_id;
    "
  done <<<"$rows"
}

xui_ensure_nginx_dynamic_proxy() {
  local snippet="/etc/nginx/snippets/includes.conf"
  [[ -f "$snippet" ]] || return 0
  grep -q '(?<fwdport>' "$snippet" 2>/dev/null && return 0
  cat >> "$snippet" <<'EOF'

# unified-proxy-manager dynamic x-ui path proxy
location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
  if ($hack = 1) { return 404; }
  client_max_body_size 0;
  client_body_timeout 1d;
  grpc_read_timeout 1d;
  grpc_socket_keepalive on;
  proxy_read_timeout 1d;
  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_request_buffering off;
  proxy_socket_keepalive on;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  if ($content_type ~* "GRPC") {
    grpc_pass grpc://127.0.0.1:$fwdport$is_args$args;
    break;
  }
  if ($http_upgrade ~* "(WEBSOCKET|WS)") {
    proxy_pass http://127.0.0.1:$fwdport$is_args$args;
    break;
  }
  if ($request_method ~* ^(PUT|POST|GET)$) {
    proxy_pass http://127.0.0.1:$fwdport$is_args$args;
    break;
  }
}
EOF
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  fi
}

xui_allow_public_inbound_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow "${port}/tcp" >/dev/null 2>&1 || true
}

xui_open_warp_reality_ports() {
  local db rows port
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  rows="$(sqlite3 -readonly "$db" "
    SELECT port
    FROM inbounds
    WHERE enable=1
      AND protocol='vless'
      AND (COALESCE(tag,'') LIKE '%-warp' OR lower(COALESCE(remark,'')) LIKE '%warp%')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='tcp'
      AND json_extract(stream_settings,'$.security')='reality';
  " 2>/dev/null || true)"
  while IFS= read -r port; do
    xui_allow_public_inbound_port "$port"
  done <<<"$rows"
}

xui_warp_mirror_stream_settings() {
  local stream_settings="$1" old_port="$2" new_port="$3"
  jq -c --argjson oldPort "${old_port:-0}" --argjson newPort "$new_port" '
    def clean_path($path):
      (($path // "") | tostring) as $p
      | if $p == "" then "warp"
        elif ($oldPort > 0 and ($p | startswith("/" + ($oldPort|tostring) + "/"))) then
          ($p | sub("^/" + ($oldPort|tostring) + "/"; ""))
        else
          ($p | sub("^/+"; ""))
        end;
    def mirror_path($path):
      "/" + ($newPort|tostring) + "/" + (clean_path($path) | sub("-warp$"; "")) + "-warp";
    def mirror_external:
      .externalProxy = (
        if ((.externalProxy // []) | length) > 0 then
          (.externalProxy | to_entries | map(if .key == 0 then (.value.port = $newPort | .value) else .value end))
        else
          [{forceTls:"same", dest:"", port:$newPort, remark:"warp"}]
        end
      );

    if ((.network // "tcp") == "tcp" and (.security // "") == "reality") then
      mirror_external
      | .tcpSettings = (.tcpSettings // {})
      | .tcpSettings.acceptProxyProtocol = false
    elif (.network // "") == "ws" then
      .wsSettings = (.wsSettings // {})
      | .wsSettings.path = mirror_path(.wsSettings.path)
    elif (.network // "") == "grpc" then
      .grpcSettings = (.grpcSettings // {})
      | .grpcSettings.serviceName = mirror_path(.grpcSettings.serviceName)
    elif (.network // "") == "xhttp" then
      .xhttpSettings = (.xhttpSettings // {})
      | .xhttpSettings.path = mirror_path(.xhttpSettings.path)
    else
      .
    end
  ' <<<"$stream_settings"
}

xui_ensure_warp_mirror_inbounds() {
  local db report_file rows inbound_id protocol tag remark port enable mirror_tag mirror_id
  local user_id up down total expiry_time listen settings stream_settings sniffing
  local new_port new_listen new_remark new_settings new_stream new_enable
  db="$(xui_db_path)"
  report_file="${1:-}"
  [[ -f "$db" ]] || return 0
  [[ "${XUI_CREATE_WARP_INBOUNDS:-1}" == "1" ]] || return 0

  rows="$(sqlite3 -separator $'\t' "$db" "
    SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), COALESCE(port,0), enable
    FROM inbounds
    WHERE protocol IN ('vless','trojan')
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
$(xui_preset_inbound_filter_sql)
    ORDER BY id;
  ")"

  while IFS=$'\t' read -r inbound_id protocol tag remark port enable; do
    [[ -n "$inbound_id" ]] || continue
    if [[ -n "$tag" ]]; then
      mirror_tag="${tag}-warp"
    else
      mirror_tag="inbound-${inbound_id}-warp"
    fi

    mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$mirror_tag") LIMIT 1;" 2>/dev/null || true)"
    user_id="$(sqlite3 -readonly "$db" "SELECT COALESCE(user_id,1) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 1)"
    up="$(sqlite3 -readonly "$db" "SELECT COALESCE(up,0) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 0)"
    down="$(sqlite3 -readonly "$db" "SELECT COALESCE(down,0) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 0)"
    total="$(sqlite3 -readonly "$db" "SELECT COALESCE(total,0) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 0)"
    expiry_time="$(sqlite3 -readonly "$db" "SELECT COALESCE(expiry_time,0) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 0)"
    listen="$(sqlite3 -readonly "$db" "SELECT COALESCE(listen,'') FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '')"
    settings="$(sqlite3 -readonly "$db" "SELECT settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
    stream_settings="$(sqlite3 -readonly "$db" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
    sniffing="$(sqlite3 -readonly "$db" "SELECT sniffing FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"

    if [[ -n "$mirror_id" ]]; then
      new_port="$(sqlite3 -readonly "$db" "SELECT COALESCE(port,0) FROM inbounds WHERE id=$mirror_id;" 2>/dev/null || echo 0)"
      [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -gt 0 ]] || new_port="$(xui_next_free_inbound_port "$db" "$(( (port > 0 ? port : 30000) + 1000 ))")"
    else
      new_port="$(xui_next_free_inbound_port "$db" "$(( (port > 0 ? port : 30000) + 1000 ))")"
    fi

    new_listen="$listen"
    if jq -e '((.network // "") == "xhttp") or (((.network // "tcp") == "tcp") and ((.security // "") == "reality"))' >/dev/null 2>&1 <<<"$stream_settings"; then
      new_listen=""
    fi
    new_remark="${remark:-inbound-$inbound_id} WARP"
    new_settings="$(jq -c '.clients = []' <<<"$settings")"
    new_stream="$(xui_warp_mirror_stream_settings "$stream_settings" "${port:-0}" "$new_port")"
    new_enable="${XUI_WARP_INBOUNDS_ENABLE:-0}"
    [[ "$new_enable" == "1" ]] || new_enable=0

    if [[ -n "$mirror_id" ]]; then
      sqlite3 "$db" "
        UPDATE inbounds
        SET remark=$(sql_quote "$new_remark"),
            enable=$new_enable,
            listen=$(sql_quote "$new_listen"),
            port=$new_port,
            protocol=$(sql_quote "$protocol"),
            stream_settings=$(sql_quote "$new_stream"),
            sniffing=$(sql_quote "$sniffing")
        WHERE id=$mirror_id;
      "
      [[ -n "$report_file" ]] && printf 'inbound=%s mirror=%s tag=%s action=updated-warp-mirror\n' "$inbound_id" "$mirror_id" "$mirror_tag" >> "$report_file"
    else
      sqlite3 "$db" "
        INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES ($user_id, $up, $down, $total, $(sql_quote "$new_remark"), $new_enable, $expiry_time, $(sql_quote "$new_listen"), $new_port, $(sql_quote "$protocol"), $(sql_quote "$new_settings"), $(sql_quote "$new_stream"), $(sql_quote "$mirror_tag"), $(sql_quote "$sniffing"));
      "
      mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$mirror_tag") LIMIT 1;" 2>/dev/null || true)"
      [[ -n "$report_file" ]] && printf 'inbound=%s mirror=%s tag=%s action=created-warp-mirror\n' "$inbound_id" "$mirror_id" "$mirror_tag" >> "$report_file"
    fi
  done <<<"$rows"

  sqlite3 "$db" "
    UPDATE inbounds
    SET listen=''
    WHERE protocol IN ('vless','trojan')
      AND listen LIKE '/%'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
      AND (COALESCE(tag,'') LIKE '%-warp' OR lower(COALESCE(remark,'')) LIKE '%warp%');
  " 2>/dev/null || true
}

xui_apply_warp_template() {
  local warp_tags_file="$1"
  local db tags_json domains_json current key keys snippet_file updated updated_count inbound_spec snippet_inbound_tags
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
      --argjson domains "$domains_json" \
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
      | .dns = (.dns // {})
      | .dns.servers = (
          (.dns.servers // [])
          | map(select(
              ((type == "object") and (((.address // "") == "https://1.1.1.1/dns-query") or ((.address // "") == "https://1.0.0.1/dns-query"))) | not
            ))
          | [
              {address:"https://1.1.1.1/dns-query", domains:$domains, skipFallback:true},
              {address:"https://1.0.0.1/dns-query", domains:$domains, skipFallback:true}
            ] + .
        )
    ' <<<"$current")"

    upm_sqlite_setting_set "$db" "$key" "$updated"

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
            else [warp_rule($domains; $inboundTags; $tag)] + .
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
