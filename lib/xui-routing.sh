#!/usr/bin/env bash

xui_db_path() {
  printf '%s\n' "${XUI_DB:-${XUIDB:-/etc/x-ui/x-ui.db}}"
}

xui_repair_invalid_inbound_settings() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  sqlite3 "$db" "
    UPDATE inbounds
    SET settings = CASE
      WHEN protocol='vless' THEN '{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}'
      WHEN protocol='trojan' THEN '{\"clients\":[],\"fallbacks\":[]}'
      WHEN protocol='shadowsocks' THEN '{\"clients\":[],\"ivCheck\":false,\"method\":\"2022-blake3-aes-256-gcm\",\"network\":\"tcp\",\"password\":\"\"}'
      WHEN protocol IN ('hysteria','hysteria2') THEN '{\"clients\":[],\"version\":2}'
      ELSE settings
    END
    WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
      AND json_valid(settings)=0;
  "
}

xui_repair_invalid_inbound_json() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  xui_repair_invalid_inbound_settings
  sqlite3 "$db" "
    UPDATE inbounds
    SET sniffing='{\"enabled\":false,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":true}'
    WHERE sniffing IS NULL OR sniffing='' OR json_valid(sniffing)=0;

    UPDATE inbounds
    SET stream_settings='{\"network\":\"tcp\",\"security\":\"none\"}'
    WHERE stream_settings IS NULL OR stream_settings='' OR json_valid(stream_settings)=0;
  "
}

xui_clear_trojan_client_flows() {
  local db fixed_settings=0 fixed_links=0 has_client_inbounds
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  fixed_settings="$(sqlite3 "$db" "
    UPDATE inbounds
    SET settings=json_set(
      settings,
      '$.clients',
      json(COALESCE((
        SELECT json_group_array(json_set(j.value, '$.flow', ''))
        FROM json_each(inbounds.settings, '$.clients') AS j
      ), '[]'))
    )
    WHERE protocol='trojan'
      AND json_valid(settings)=1
      AND EXISTS (
        SELECT 1
        FROM json_each(inbounds.settings, '$.clients') AS j
        WHERE COALESCE(json_extract(j.value, '$.flow'), '') <> ''
      );
    SELECT changes();
  ")"

  has_client_inbounds="$(sqlite3 -readonly "$db" "
    SELECT COUNT(*)
    FROM sqlite_master
    WHERE type='table' AND name='client_inbounds';
  ")"
  if [[ "$has_client_inbounds" == "1" ]]; then
    fixed_links="$(sqlite3 "$db" "
      UPDATE client_inbounds
      SET flow_override=''
      WHERE COALESCE(flow_override, '') <> ''
        AND inbound_id IN (
          SELECT id FROM inbounds WHERE protocol='trojan'
        );
      SELECT changes();
    ")"
  fi

  if [[ "$fixed_settings" =~ ^[0-9]+$ && "$fixed_links" =~ ^[0-9]+$ ]] \
    && (( fixed_settings + fixed_links > 0 )); then
    printf 'INFO: Cleared unsupported Trojan flow from %s inbound JSON record(s) and %s v3 link(s)\n' \
      "$fixed_settings" "$fixed_links"
  fi
}

xui_shadowsocks_2022_key_bytes() {
  case "$1" in
    2022-blake3-aes-128-gcm) printf '16\n' ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32\n' ;;
    *) printf '0\n' ;;
  esac
}

xui_shadowsocks_2022_key_valid() {
  local key="$1" expected_bytes="$2" decoded_bytes tmp
  [[ "$expected_bytes" =~ ^[0-9]+$ && "$expected_bytes" -gt 0 ]] || return 1
  tmp="$(mktemp)"
  if ! printf '%s' "$key" | base64 -d >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  decoded_bytes="$(wc -c < "$tmp" | tr -d '[:space:]')"
  rm -f "$tmp"
  [[ "$decoded_bytes" == "$expected_bytes" ]]
}

xui_new_shadowsocks_2022_key() {
  openssl rand -base64 "$1" | tr -d '\r\n'
}

xui_repair_shadowsocks_2022_keys() {
  local db rows inbound_id settings method key_bytes server_key new_settings new_key
  local client_count index client_key client_id email has_client_inbounds
  local fixed_settings=0 fixed_records=0
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  for command_name in sqlite3 jq openssl base64; do
    command -v "$command_name" >/dev/null 2>&1 || return 0
  done

  has_client_inbounds="$(sqlite3 -readonly "$db" "
    SELECT COUNT(*)
    FROM sqlite_master
    WHERE type='table' AND name='client_inbounds';
  ")"
  rows="$(sqlite3 -readonly -separator $'\t' "$db" "
    SELECT id, json(settings)
    FROM inbounds
    WHERE protocol='shadowsocks' AND json_valid(settings)=1
    ORDER BY id;
  ")"
  while IFS=$'\t' read -r inbound_id settings; do
    [[ -n "$inbound_id" && -n "$settings" ]] || continue
    method="$(jq -r '.method // ""' <<<"$settings")"
    key_bytes="$(xui_shadowsocks_2022_key_bytes "$method")"
    [[ "$key_bytes" -gt 0 ]] || continue
    new_settings="$settings"

    server_key="$(jq -r '.password // ""' <<<"$new_settings")"
    if ! xui_shadowsocks_2022_key_valid "$server_key" "$key_bytes"; then
      new_key="$(xui_new_shadowsocks_2022_key "$key_bytes")"
      new_settings="$(jq -c --arg password "$new_key" '.password=$password' <<<"$new_settings")"
      fixed_settings=$((fixed_settings + 1))
    fi

    client_count="$(jq '(.clients // []) | length' <<<"$new_settings")"
    for ((index = 0; index < client_count; index++)); do
      client_key="$(jq -r --argjson index "$index" '.clients[$index].password // ""' <<<"$new_settings")"
      if ! xui_shadowsocks_2022_key_valid "$client_key" "$key_bytes"; then
        new_key="$(xui_new_shadowsocks_2022_key "$key_bytes")"
        new_settings="$(jq -c --argjson index "$index" --arg password "$new_key" '.clients[$index].password=$password' <<<"$new_settings")"
        fixed_settings=$((fixed_settings + 1))
      fi
    done

    if [[ "$has_client_inbounds" == "1" ]]; then
      while IFS=$'\t' read -r client_id email client_key; do
        [[ -n "$client_id" ]] || continue
        client_key="${client_key//$'\r'/}"
        if ! xui_shadowsocks_2022_key_valid "$client_key" "$key_bytes"; then
          new_key="$(xui_new_shadowsocks_2022_key "$key_bytes")"
          sqlite3 "$db" "UPDATE clients SET password=$(sql_quote "$new_key") WHERE id=$client_id;"
          new_settings="$(jq -c --arg email "$email" --arg password "$new_key" '
            .clients = [(.clients // [])[] | if ((.email // "") == $email) then .password=$password else . end]
          ' <<<"$new_settings")"
          fixed_records=$((fixed_records + 1))
        fi
      done < <(sqlite3 -readonly -separator $'\t' "$db" "
        SELECT c.id, COALESCE(c.email, ''), COALESCE(c.password, '')
        FROM clients c
        JOIN client_inbounds ci ON ci.client_id=c.id
        WHERE ci.inbound_id=$inbound_id
        ORDER BY c.id;
      ")
    fi

    [[ "$new_settings" == "$settings" ]] || \
      sqlite3 "$db" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  done <<<"$rows"

  if (( fixed_settings + fixed_records > 0 )); then
    printf 'INFO: Repaired Shadowsocks 2022 key(s): %s inbound JSON value(s), %s v3 client record(s)\n' \
      "$fixed_settings" "$fixed_records"
  fi
}

xui_xray_core_running() {
  command -v ps >/dev/null 2>&1 || return 0
  ps -eo comm= 2>/dev/null | awk '
    $1 == "xray" || $1 ~ /^xray-linux-/ { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

xui_xray_core_listening() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltnup 2>/dev/null | grep -Eq 'users:\(\("xray(-linux-[^"]*)?"'
}

xui_wait_for_xray_core() {
  local timeout_seconds="${1:-10}" waited=0 stable_seconds=0
  while (( waited < timeout_seconds )); do
    if xui_xray_core_running && xui_xray_core_listening; then
      stable_seconds=$((stable_seconds + 1))
      (( stable_seconds >= 3 )) && return 0
    else
      stable_seconds=0
    fi
    sleep 1
    ((waited += 1))
  done
  return 1
}

xui_sanitize_inbound_tags() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  sqlite3 "$db" "
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

xui_generated_client_base() {
  printf '%s\n' "$1"
}

xui_existing_generated_client_json() {
  local settings="$1" email="$2" sub_id="$3" sub_id_mode="${4:-per-client}"
  jq -c \
    --arg email "$email" \
    --arg sub_id "$sub_id" \
    --argjson match_sub_id "$([[ "$sub_id_mode" == "per-client" ]] && printf true || printf false)" '
    ((.clients // []) | map(select((.email // "") == $email)) | .[0])
    // (if $match_sub_id then
          ((.clients // []) | map(select((.subId // "") == $sub_id)) | .[0])
        else null end)
    // {}
  ' <<<"$settings"
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
             AND json_extract(stream_settings,'$.network') IN ('ws','xhttp','grpc'))
         OR (protocol='trojan'
             AND json_valid(stream_settings)=1
             AND json_extract(stream_settings,'$.network') IN ('tcp','grpc'))
         OR (protocol='shadowsocks'
             AND json_valid(stream_settings)=1
             AND json_extract(stream_settings,'$.network')='tcp')
         OR (protocol IN ('hysteria','hysteria2')
             AND json_valid(stream_settings)=1
             AND json_extract(stream_settings,'$.network')='hysteria')
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
    WHERE protocol IN ('vless','trojan','shadowsocks','hysteria','hysteria2')
$(xui_preset_inbound_filter_sql)
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
  "
}

xui_remove_deprecated_vmess_presets() {
  local db removed
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  removed="$(sqlite3 "$db" "
    DELETE FROM client_traffics
    WHERE inbound_id IN (
      SELECT id
      FROM inbounds
      WHERE protocol='vmess'
        AND lower(COALESCE(remark,'')) LIKE '%vmess-tcp%'
    );

    DELETE FROM inbounds
    WHERE protocol='vmess'
      AND lower(COALESCE(remark,'')) LIKE '%vmess-tcp%';

    SELECT changes();
  " 2>/dev/null || true)"
  removed="${removed##*$'\n'}"
  if [[ "$removed" =~ ^[0-9]+$ && "$removed" -gt 0 ]]; then
    printf 'INFO: Removed deprecated VMess preset inbound(s): %s\n' "$removed"
  fi
}

xui_disable_experimental_trojan_grpc_presets() {
  local db disabled
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  disabled="$(sqlite3 "$db" "
    UPDATE inbounds
    SET enable=0
    WHERE enable != 0
      AND protocol='trojan'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND COALESCE(json_extract(stream_settings,'$.security'), 'none') != 'none'
      AND lower(COALESCE(remark,'')) LIKE '%trojan-grpc%';

    SELECT changes();
  " 2>/dev/null || true)"
  disabled="${disabled##*$'\n'}"
  if [[ "$disabled" =~ ^[0-9]+$ && "$disabled" -gt 0 ]]; then
    printf 'INFO: Disabled unsupported Trojan gRPC preset inbound(s): %s\n' "$disabled"
  fi
}

xui_normalize_reference_preset_external_proxy_ports() {
  local db updated domain_updated public_domain ws_rows inbound_id inbound_port stream new_stream
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  public_domain="${XUI_PUBLIC_DOMAIN:-${XUI_DOMAIN:-}}"
  # Reality (tcp/xhttp/grpc), trojan-reality and vless-ws are reachable on
  # public TCP 443: nginx stream SNI passthrough for the reality family and
  # nginx domain vhost path-proxy for ws. shadowsocks and hysteria2 keep their
  # dedicated listening ports, so their published ports must match them.
  updated="$(sqlite3 "$db" "
    UPDATE inbounds
    SET stream_settings=json_set(
      stream_settings,
      '$.externalProxy[0].port', 443,
      '$.sockopt.acceptProxyProtocol', json('true')
    )
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND json_extract(stream_settings, '$.security')='reality'
      AND (
        CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != 443
        OR COALESCE(json_extract(stream_settings, '$.sockopt.acceptProxyProtocol'), 0) != 1
      )
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND (
        lower(COALESCE(remark,'')) LIKE '%vless-tcp-reality%'
        OR lower(COALESCE(remark,'')) LIKE '%vless-xhttp-reality%'
        OR lower(COALESCE(remark,'')) LIKE '%vless-grpc%'
        OR lower(COALESCE(remark,'')) LIKE '%trojan-tcp-reality%'
        OR lower(COALESCE(remark,'')) LIKE '%trojan-grpc%'
      );

    UPDATE inbounds
    SET stream_settings=json_set(
      stream_settings,
      '$.externalProxy[0].port', 443,
      '$.externalProxy[0].forceTls', 'tls',
      '$.xhttpSettings.path',
        CASE
          WHEN COALESCE(json_extract(stream_settings, '$.xhttpSettings.path'), '') LIKE '/' || port || '/%'
            THEN json_extract(stream_settings, '$.xhttpSettings.path')
          ELSE '/' || port || '/' || ltrim(COALESCE(json_extract(stream_settings, '$.xhttpSettings.path'), ''), '/')
        END,
      '$.sockopt.acceptProxyProtocol', json('false')
    )
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND lower(COALESCE(remark,'')) LIKE '%vless-xhttp%'
      AND (
        CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != 443
        OR COALESCE(json_extract(stream_settings, '$.externalProxy[0].forceTls'), '') != 'tls'
        OR COALESCE(json_extract(stream_settings, '$.xhttpSettings.path'), '') NOT LIKE '/' || port || '/%'
        OR COALESCE(json_extract(stream_settings, '$.sockopt.acceptProxyProtocol'), 0) != 0
      );

    UPDATE inbounds
    SET stream_settings=json_set(
      stream_settings,
      '$.externalProxy[0].port', 443,
      '$.externalProxy[0].forceTls', 'tls',
      '$.grpcSettings.serviceName',
        CASE
          WHEN COALESCE(json_extract(stream_settings, '$.grpcSettings.serviceName'), '') LIKE port || '/%'
            THEN json_extract(stream_settings, '$.grpcSettings.serviceName')
          ELSE port || '/' || ltrim(COALESCE(json_extract(stream_settings, '$.grpcSettings.serviceName'), 'trojan-grpc'), '/')
        END
    )
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND protocol='trojan'
      AND json_extract(stream_settings, '$.network')='grpc'
      AND (
        CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != 443
        OR COALESCE(json_extract(stream_settings, '$.externalProxy[0].forceTls'), '') != 'tls'
        OR COALESCE(json_extract(stream_settings, '$.grpcSettings.serviceName'), '') NOT LIKE port || '/%'
      );

    UPDATE inbounds
    SET stream_settings=json_set(
      stream_settings,
      '$.externalProxy[0].port', 443,
      '$.wsSettings.path',
        CASE
          WHEN COALESCE(json_extract(stream_settings, '$.wsSettings.path'), '') LIKE '/' || port || '/%'
            THEN json_extract(stream_settings, '$.wsSettings.path')
          ELSE '/' || port || '/' || ltrim(COALESCE(json_extract(stream_settings, '$.wsSettings.path'), ''), '/')
        END,
      '$.wsSettings.acceptProxyProtocol', json('false')
    )
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND lower(COALESCE(remark,'')) LIKE '%vless-ws%'
      AND (
        CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != 443
        OR COALESCE(json_extract(stream_settings, '$.wsSettings.path'), '') NOT LIKE '/' || port || '/%'
        OR COALESCE(json_extract(stream_settings, '$.wsSettings.acceptProxyProtocol'), 0) != 0
      );

    UPDATE inbounds
    SET stream_settings=json_set(stream_settings, '$.externalProxy[0].port', port)
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != port
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND (
        lower(COALESCE(remark,'')) LIKE '%shadowsocks-tcp%'
        OR lower(COALESCE(remark,'')) LIKE '%shadowsocks%'
        OR lower(COALESCE(remark,'')) LIKE '%hysteria2-udp%'
        OR lower(COALESCE(remark,'')) LIKE '%hysteria2%'
      );

    SELECT total_changes();
  " 2>/dev/null || true)"
  updated="${updated##*$'\n'}"
  if [[ "$updated" =~ ^[0-9]+$ && "$updated" -gt 0 ]]; then
    printf 'INFO: Normalized reference preset public port(s): %s\n' "$updated"
  fi
  if [[ "$public_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
    domain_updated="$(sqlite3 "$db" "
      UPDATE inbounds
      SET stream_settings=json_set(stream_settings, '$.externalProxy[0].dest', $(sql_quote "$public_domain"))
      WHERE json_valid(stream_settings)=1
        AND json_type(stream_settings, '$.externalProxy[0]')='object'
$(xui_preset_inbound_filter_sql)
        AND COALESCE(json_extract(stream_settings, '$.externalProxy[0].dest'), '') != $(sql_quote "$public_domain");

      SELECT changes();
    " 2>/dev/null || true)"
    domain_updated="${domain_updated##*$'\n'}"
    if [[ "$domain_updated" =~ ^[0-9]+$ && "$domain_updated" -gt 0 ]]; then
      printf 'INFO: Normalized reference preset public domain(s): %s -> %s\n' "$domain_updated" "$public_domain"
    fi
  fi
  if [[ "$public_domain" =~ ^[A-Za-z0-9.-]+$ ]] && command -v jq >/dev/null 2>&1; then
    ws_rows="$(sqlite3 -separator $'\t' "$db" "
      SELECT id, port, json(stream_settings)
      FROM inbounds
      WHERE json_valid(stream_settings)=1
        AND json_extract(stream_settings,'$.network')='ws'
        AND COALESCE(tag,'') NOT LIKE '%-warp'
        AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
        AND lower(COALESCE(remark,'')) LIKE '%vless-ws%';
    " 2>/dev/null || true)"
    while IFS=$'\t' read -r inbound_id inbound_port stream; do
      [[ "$inbound_id" =~ ^[0-9]+$ && "$inbound_port" =~ ^[0-9]+$ && -n "$stream" ]] || continue
      new_stream="$(jq -c --arg domain "$public_domain" --argjson port "$inbound_port" '
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
      ' <<<"$stream")" || continue
      sqlite3 "$db" "UPDATE inbounds SET stream_settings=$(sql_quote "$new_stream") WHERE id=$inbound_id;"
    done <<<"$ws_rows"

    local xhttp_rows grpc_rows
    xhttp_rows="$(sqlite3 -separator $'\t' "$db" "
      SELECT id, port, json(stream_settings)
      FROM inbounds
      WHERE json_valid(stream_settings)=1
        AND json_extract(stream_settings,'$.network')='xhttp'
        AND COALESCE(tag,'') NOT LIKE '%-warp'
        AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
        AND lower(COALESCE(remark,'')) LIKE '%vless-xhttp%';
    " 2>/dev/null || true)"
    while IFS=$'\t' read -r inbound_id inbound_port stream; do
      [[ "$inbound_id" =~ ^[0-9]+$ && "$inbound_port" =~ ^[0-9]+$ && -n "$stream" ]] || continue
      new_stream="$(jq -c --arg domain "$public_domain" --argjson port "$inbound_port" '
        .security = "none"
        | .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"tls",dest:"",port:443,remark:""}] end)
        | .externalProxy[0].forceTls = "tls"
        | .externalProxy[0].dest = $domain
        | .externalProxy[0].port = 443
        | .externalProxy[0].remark = ""
        | .xhttpSettings = (.xhttpSettings // {})
        | .xhttpSettings.host = $domain
        | .xhttpSettings.path = ("/" + ($port|tostring) + "/")
        | .xhttpSettings.mode = (.xhttpSettings.mode // "packet-up")
        | .xhttpSettings.headers = (.xhttpSettings.headers // {})
        | .sockopt = (.sockopt // {})
        | .sockopt.acceptProxyProtocol = false
      ' <<<"$stream")" || continue
      sqlite3 "$db" "UPDATE inbounds SET stream_settings=$(sql_quote "$new_stream") WHERE id=$inbound_id;"
    done <<<"$xhttp_rows"

    grpc_rows="$(sqlite3 -separator $'\t' "$db" "
      SELECT id, port, json(stream_settings)
      FROM inbounds
      WHERE json_valid(stream_settings)=1
        AND protocol='trojan'
        AND json_extract(stream_settings,'$.network')='grpc'
        AND COALESCE(tag,'') NOT LIKE '%-warp'
        AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';
    " 2>/dev/null || true)"
    while IFS=$'\t' read -r inbound_id inbound_port stream; do
      [[ "$inbound_id" =~ ^[0-9]+$ && "$inbound_port" =~ ^[0-9]+$ && -n "$stream" ]] || continue
      new_stream="$(jq -c --arg domain "$public_domain" --argjson port "$inbound_port" '
        .security = "none"
        | .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"tls",dest:"",port:443,remark:""}] end)
        | .externalProxy[0].forceTls = "tls"
        | .externalProxy[0].dest = $domain
        | .externalProxy[0].port = 443
        | .externalProxy[0].remark = ""
        | .grpcSettings = (.grpcSettings // {})
        | .grpcSettings.authority = $domain
        | .grpcSettings.serviceName = (($port|tostring) + "/" + (((.grpcSettings.serviceName // "trojan-grpc") | tostring) | sub("^/*[0-9]+/*"; "") | sub("^/+"; "")))
        | .grpcSettings.multiMode = (.grpcSettings.multiMode // false)
      ' <<<"$stream")" || continue
      sqlite3 "$db" "UPDATE inbounds SET stream_settings=$(sql_quote "$new_stream") WHERE id=$inbound_id;"
    done <<<"$grpc_rows"
  fi
}

xui_enable_warp_domain_sniffing() {
  xui_enable_preset_domain_sniffing
}

xui_normalize_reference_preset_remarks() {
  local db emoji_flag prefix rows inbound_id index
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  emoji_flag="${XUI_EMOJI_FLAG:-🇫🇮}"
  if [[ -n "$emoji_flag" ]]; then
    prefix="${emoji_flag} "
  else
    prefix=""
  fi

  rows="$(sqlite3 -readonly "$db" "
    SELECT id
    FROM inbounds
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='tcp'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
    ORDER BY id
    LIMIT 4;
  " 2>/dev/null || true)"
  index=0
  while IFS= read -r inbound_id; do
    [[ "$inbound_id" =~ ^[0-9]+$ ]] || continue
    index=$((index + 1))
    sqlite3 "$db" "UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-tcp-reality-${index}") WHERE id=$inbound_id;"
  done <<<"$rows"

  sqlite3 "$db" "
    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-xhttp-reality")
    WHERE protocol='vless' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-xhttp")
    WHERE protocol='vless' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
      AND COALESCE(json_extract(stream_settings,'$.security'),'none')!='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-grpc-reality")
    WHERE protocol='vless' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-ws")
    WHERE protocol='vless' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='ws'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}shadowsocks")
    WHERE protocol='shadowsocks'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}hysteria2")
    WHERE protocol IN ('hysteria','hysteria2')
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}trojan-tcp-reality")
    WHERE protocol='trojan' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='tcp'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}trojan-grpc")
    WHERE protocol='trojan' AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-reality-warp")
    WHERE COALESCE(tag,'')='upm-v3-warp-reality';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}vless-xhttp-warp")
    WHERE COALESCE(tag,'')='upm-v3-warp-xhttp';

    UPDATE inbounds SET remark=$(sql_quote "${prefix}hysteria2-warp")
    WHERE COALESCE(tag,'')='upm-v3-warp-hysteria2';
  " 2>/dev/null || true
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
  rows="$(sqlite3 "$db" "
    SELECT id
    FROM inbounds
    WHERE protocol IN ('vless','trojan')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
    ORDER BY id;
  " 2>/dev/null || true)"

  while IFS= read -r inbound_id; do
    [[ -n "$inbound_id" ]] || continue
    port="$(sqlite3 -readonly "$db" "SELECT COALESCE(port,0) FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo 0)"
    listen="$(sqlite3 -readonly "$db" "SELECT COALESCE(listen,'') FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '')"
    stream_settings="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
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

xui_normalize_grpc_service_names() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  sqlite3 "$db" "
    UPDATE inbounds
    SET stream_settings = json_set(
      stream_settings,
      '$.grpcSettings.serviceName',
      ltrim(COALESCE(json_extract(stream_settings,'$.grpcSettings.serviceName'), ''), '/')
    )
    WHERE protocol IN ('vless','trojan')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND COALESCE(json_extract(stream_settings,'$.grpcSettings.serviceName'), '') LIKE '/%';
  " 2>/dev/null || true
}

xui_restore_reference_vless_grpc_reality_inbounds() {
  local db rows key_row inbound_id remark public_domain stream_settings
  local private_key public_key decoy sid1 sid2 new_remark new_stream updated=0
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  rows="$(sqlite3 -separator $'\t' -readonly "$db" "
    SELECT id,
           COALESCE(remark,''),
           COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),''),
           json(stream_settings)
    FROM inbounds
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND json_extract(stream_settings,'$.security')='tls'
      AND CAST(COALESCE(json_extract(stream_settings,'$.externalProxy[0].port'),0) AS INTEGER)=port
      AND COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),'') <> ''
      AND lower(COALESCE(remark,'')) LIKE '%vless-grpc-tls%'
    ORDER BY id;
  " 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0

  key_row="$(sqlite3 -separator $'\t' -readonly "$db" "
    SELECT COALESCE(json_extract(stream_settings,'$.realitySettings.privateKey'),''),
           COALESCE(json_extract(stream_settings,'$.realitySettings.settings.publicKey'),'')
    FROM inbounds
    WHERE json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(json_extract(stream_settings,'$.realitySettings.privateKey'),'') <> ''
      AND COALESCE(json_extract(stream_settings,'$.realitySettings.settings.publicKey'),'') <> ''
    ORDER BY id
    LIMIT 1;
  " 2>/dev/null || true)"
  IFS=$'\t' read -r private_key public_key <<<"$key_row"
  [[ -n "$private_key" && -n "$public_key" ]] || {
    warn "Cannot restore VLESS gRPC REALITY preset: no existing REALITY key pair found"
    return 0
  }

  decoy="${REALITY_GRPC_DECOY:-dzen.ru}"
  while IFS=$'\t' read -r inbound_id remark public_domain stream_settings; do
    [[ -n "$inbound_id" && -n "$public_domain" ]] || continue
    sid1="$(openssl rand -hex 4)"
    sid2="$(openssl rand -hex 4)"
    new_remark="${remark//grpc-tls/grpc-reality}"
    new_stream="$(jq -c \
      --arg decoy "$decoy" \
      --arg privateKey "$private_key" \
      --arg publicKey "$public_key" \
      --arg sid1 "$sid1" \
      --arg sid2 "$sid2" '
      .security = "reality"
      | del(.tlsSettings)
      | .externalProxy[0].forceTls = "same"
      | .externalProxy[0].port = 443
      | .sockopt = (.sockopt // {})
      | .sockopt.acceptProxyProtocol = true
      | .grpcSettings = (.grpcSettings // {})
      | .grpcSettings.authority = $decoy
      | .realitySettings = {
          show:false,
          xver:0,
          target:($decoy + ":443"),
          dest:($decoy + ":443"),
          serverNames:[$decoy],
          privateKey:$privateKey,
          shortIds:[$sid1,$sid2],
          settings:{publicKey:$publicKey,fingerprint:"random",serverName:"",spiderX:"/"}
        }
    ' <<<"$stream_settings")"
    sqlite3 "$db" "
      UPDATE inbounds
      SET remark=$(sql_quote "$new_remark"),
          stream_settings=$(sql_quote "$new_stream")
      WHERE id=$inbound_id;
    "
    updated=$((updated + 1))
  done <<<"$rows"

  if [[ "$updated" -gt 0 ]]; then
    printf 'INFO: Restored VLESS gRPC REALITY preset inbound(s): %s\n' "$updated"
  fi
}

xui_disable_nginx_enabled_backup_configs() {
  local enabled_dir="${NGINX_SITES_ENABLED_DIR:-/etc/nginx/sites-enabled}" disabled_dir file base stamp
  [[ -d "$enabled_dir" ]] || return 0
  disabled_dir="/etc/nginx/sites-disabled-upm-backups"
  stamp="$(date '+%Y%m%d%H%M%S' 2>/dev/null || printf 'now')"
  mkdir -p "$disabled_dir" 2>/dev/null || return 0
  shopt -s nullglob
  for file in "$enabled_dir"/*.bak "$enabled_dir"/*.old "$enabled_dir"/*.orig "$enabled_dir"/*.save "$enabled_dir"/*.disabled; do
    [[ -e "$file" || -L "$file" ]] || continue
    base="$(basename "$file")"
    mv -f -- "$file" "$disabled_dir/${base}.${stamp}" 2>/dev/null || rm -f -- "$file" 2>/dev/null || true
    warn "disabled nginx backup config from sites-enabled: $file"
  done
  shopt -u nullglob
}

xui_ensure_nginx_xui_domain_route() {
  local domain domain_key stream_conf backup tmp_stream
  domain="${XUI_PUBLIC_DOMAIN:-${XUI_DOMAIN:-}}"
  stream_conf="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 0
  [[ -f "$stream_conf" ]] || return 0
  grep -q 'map[[:space:]]\+\$ssl_preread_server_name[[:space:]]\+\$sni_name' "$stream_conf" 2>/dev/null || return 0

  domain_key="${domain,,}"
  backup="$(mktemp)"
  tmp_stream="$(mktemp)"
  cp -a "$stream_conf" "$backup"

  awk -v domain="$domain" -v domain_key="$domain_key" '
    BEGIN {
      in_map = 0
      inserted_route = 0
      skip_upstream_www = 0
      upstream_depth = 0
    }
    function route_key(line,    cleaned, parts) {
      cleaned = line
      sub(/#.*/, "", cleaned)
      gsub(/;/, "", cleaned)
      sub(/^[[:space:]]+/, "", cleaned)
      sub(/[[:space:]]+$/, "", cleaned)
      split(cleaned, parts, /[[:space:]]+/)
      return tolower(parts[1])
    }
    function print_xui_route() {
      if (inserted_route) return
      printf "    %-32s www; # upm-xui-domain\n", domain
      inserted_route = 1
    }
    function brace_delta(line,    opens, closes, tmp) {
      tmp = line
      opens = gsub(/\{/, "{", tmp)
      tmp = line
      closes = gsub(/\}/, "}", tmp)
      return opens - closes
    }
    $0 ~ /^[[:space:]]*upstream[[:space:]]+www[[:space:]]*\{/ {
      skip_upstream_www = 1
      upstream_depth = brace_delta($0)
      if (upstream_depth <= 0) skip_upstream_www = 0
      next
    }
    skip_upstream_www {
      upstream_depth += brace_delta($0)
      if (upstream_depth <= 0) skip_upstream_www = 0
      next
    }
    $0 ~ /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name[[:space:]]*\{/ {
      in_map = 1
      print
      next
    }
    in_map && $0 ~ /^[[:space:]]*hostnames;[[:space:]]*$/ {
      print
      print_xui_route()
      next
    }
    in_map && $0 ~ /^[[:space:]]*\}/ {
      print_xui_route()
      in_map = 0
      print
      next
    }
    in_map {
      if (route_key($0) == domain_key) next
      if ($0 ~ /#[[:space:]]*upm-xui-domain[[:space:]]*$/) next
    }
    { print }
    END {
      print ""
      print "upstream www {"
      print "    server 127.0.0.1:7443;"
      print "}"
      if (!inserted_route) exit 42
    }
  ' "$stream_conf" > "$tmp_stream" || {
    rm -f "$backup" "$tmp_stream"
    return 1
  }

  install -m 0644 "$tmp_stream" "$stream_conf"
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      cp -a "$backup" "$stream_conf" 2>/dev/null || true
      warn "nginx x-ui public domain stream route update failed validation; restored $stream_conf"
      rm -f "$backup" "$tmp_stream"
      return 1
    fi
  fi
  rm -f "$backup" "$tmp_stream"
}

xui_ensure_nginx_reality_sni_routes() {
  local db stream_conf upstream_conf backup_stream backup_upstreams had_upstreams=0
  local tmp_stream tmp_upstreams map_routes map_keys rows inbound_id port sni upstream key
  local public_domain public_domain_key
  db="$(xui_db_path)"
  stream_conf="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
  upstream_conf="${NGINX_XUI_REALITY_UPSTREAM_CONF:-/etc/nginx/stream-enabled/upm-xui-reality.conf}"
  public_domain="${XUI_PUBLIC_DOMAIN:-${XUI_DOMAIN:-}}"
  public_domain_key="${public_domain,,}"
  [[ -f "$db" && -f "$stream_conf" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  grep -q 'map[[:space:]]\+\$ssl_preread_server_name[[:space:]]\+\$sni_name' "$stream_conf" 2>/dev/null || return 0

  rows="$(sqlite3 -separator $'\t' -readonly "$db" "
    WITH reality_inbounds AS (
      SELECT id, port, stream_settings
      FROM inbounds
      WHERE enable=1
        AND protocol IN ('vless','trojan')
        AND json_valid(stream_settings)=1
        AND json_extract(stream_settings,'$.network') IN ('tcp','xhttp','grpc')
        AND json_extract(stream_settings,'$.security')='reality'
        AND (
          COALESCE(tag,'') LIKE 'upm-v3-warp-%'
          OR (COALESCE(tag,'') NOT LIKE '%-warp' AND lower(COALESCE(remark,'')) NOT LIKE '%warp%')
        )
    ),
    names AS (
      SELECT reality_inbounds.id, reality_inbounds.port, trim(server_name.value) AS name
      FROM reality_inbounds,
           json_each(COALESCE(json_extract(stream_settings,'$.realitySettings.serverNames'),'[]')) AS server_name
      UNION
      SELECT reality_inbounds.id, reality_inbounds.port, trim(COALESCE(json_extract(stream_settings,'$.realitySettings.settings.serverName'),'')) AS name
      FROM reality_inbounds
    )
    SELECT DISTINCT id, port, name
    FROM names
    WHERE name <> ''
    ORDER BY id, name;
  " 2>/dev/null || true)"

  map_routes="$(mktemp)"
  map_keys="$(mktemp)"
  tmp_stream="$(mktemp)"
  tmp_upstreams="$(mktemp)"
  : > "$map_routes"
  : > "$map_keys"
  printf '# Managed by unified-proxy-manager. Do not edit.\n' > "$tmp_upstreams"

  declare -A route_ports=()
  declare -A upstreams=()
  while IFS=$'\t' read -r inbound_id port sni; do
    inbound_id="${inbound_id//$'\r'/}"
    port="${port//$'\r'/}"
    sni="${sni//$'\r'/}"
    [[ -n "$inbound_id" && -n "$port" && -n "$sni" ]] || continue
    [[ "$inbound_id" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$port" -le 65535 ]] || {
      warn "invalid REALITY route row: inbound=$inbound_id port=$port sni=$sni"
      rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams"
      return 1
    }
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
      warn "invalid REALITY SNI in x-ui database: $sni"
      rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams"
      return 1
    }
    key="${sni,,}"
    if [[ -n "$public_domain_key" && "$key" == "$public_domain_key" ]]; then
      warn "REALITY SNI $sni conflicts with x-ui public domain; keeping $sni routed to nginx www upstream"
      continue
    fi
    if [[ -n "${route_ports[$key]:-}" && "${route_ports[$key]}" != "$port" ]]; then
      warn "REALITY SNI $sni is assigned to multiple backend ports (${route_ports[$key]} and $port); each public-443 REALITY preset needs a unique SNI"
      rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams"
      return 1
    fi
    route_ports["$key"]="$port"
    upstream="upm_xui_reality_${inbound_id}"
    if ! grep -Fqx "$key" "$map_keys"; then
      printf '%s\n' "$key" >> "$map_keys"
      printf '    %-32s %s; # upm-xui-reality\n' "$sni" "$upstream" >> "$map_routes"
    fi
    if [[ -z "${upstreams[$upstream]:-}" ]]; then
      upstreams["$upstream"]=1
      printf '\nupstream %s {\n    server 127.0.0.1:%s;\n}\n' "$upstream" "$port" >> "$tmp_upstreams"
    fi
  done <<<"$rows"

  backup_stream="$(mktemp)"
  cp -a "$stream_conf" "$backup_stream"
  backup_upstreams="$(mktemp)"
  if [[ -f "$upstream_conf" ]]; then
    cp -a "$upstream_conf" "$backup_upstreams"
    had_upstreams=1
  fi

  awk -v routes_file="$map_routes" -v keys_file="$map_keys" '
    BEGIN {
      while ((getline line < routes_file) > 0) {
        routes[++route_count] = line
      }
      close(routes_file)
      while ((getline line < keys_file) > 0) {
        managed[line] = 1
      }
      close(keys_file)
      in_map = 0
      inserted = 0
      skipping = 0
    }
    function map_key(line,    cleaned, parts) {
      cleaned = line
      sub(/#.*/, "", cleaned)
      gsub(/;/, "", cleaned)
      sub(/^[[:space:]]+/, "", cleaned)
      sub(/[[:space:]]+$/, "", cleaned)
      split(cleaned, parts, /[[:space:]]+/)
      return parts[1]
    }
    function print_routes(    i) {
      if (inserted) return
      print "    # BEGIN unified-proxy-manager x-ui reality routes"
      for (i = 1; i <= route_count; i++) {
        print routes[i]
      }
      print "    # END unified-proxy-manager x-ui reality routes"
      inserted = 1
    }
    $0 ~ /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name[[:space:]]*\{/ {
      in_map = 1
      print
      next
    }
    in_map && $0 ~ /^[[:space:]]*#[[:space:]]*BEGIN unified-proxy-manager x-ui reality routes[[:space:]]*$/ {
      skipping = 1
      next
    }
    in_map && $0 ~ /^[[:space:]]*#[[:space:]]*END unified-proxy-manager x-ui reality routes[[:space:]]*$/ {
      skipping = 0
      next
    }
    in_map && skipping {
      next
    }
    in_map && $0 ~ /^[[:space:]]*hostnames;[[:space:]]*$/ {
      print
      print_routes()
      next
    }
    in_map && $0 ~ /^[[:space:]]*\}/ {
      print_routes()
      in_map = 0
      print
      next
    }
    in_map {
      candidate = map_key($0)
      if (tolower(candidate) in managed) next
      if ($0 ~ /#[[:space:]]*upm-xui-reality[[:space:]]*$/) next
    }
    { print }
    END {
      if (!inserted) exit 42
    }
  ' "$stream_conf" > "$tmp_stream" || {
    rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams" "$backup_stream" "$backup_upstreams"
    return 1
  }
  install -m 0644 "$tmp_stream" "$stream_conf"
  install -m 0644 "$tmp_upstreams" "$upstream_conf"

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      cp -a "$backup_stream" "$stream_conf" 2>/dev/null || true
      if [[ "$had_upstreams" == "1" ]]; then
        cp -a "$backup_upstreams" "$upstream_conf" 2>/dev/null || true
      else
        rm -f "$upstream_conf"
      fi
      warn "nginx Reality SNI stream route update failed validation; restored $stream_conf"
      rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams" "$backup_stream" "$backup_upstreams"
      return 1
    fi
  fi
  rm -f "$map_routes" "$map_keys" "$tmp_stream" "$tmp_upstreams" "$backup_stream" "$backup_upstreams"
}

xui_ensure_nginx_dynamic_proxy() {
  local snippet="/etc/nginx/snippets/includes.conf" backup had_dynamic=0
  [[ -f "$snippet" ]] || return 0
  backup="$(mktemp)"
  cp -a "$snippet" "$backup" 2>/dev/null || backup=""
  grep -q '(?<fwdport>' "$snippet" 2>/dev/null && had_dynamic=1
  sed -i \
    -e 's/\$content_type[[:space:]]*~\*[[:space:]]*"GRPC"/$http_content_type ~* "grpc"/g' \
    -e 's/\$content_type[[:space:]]*~\*[[:space:]]*"grpc"/$http_content_type ~* "grpc"/g' \
    -e 's#grpc_pass grpc://127\.0\.0\.1:\$fwdport\$is_args\$args;#grpc_pass grpc://127.0.0.1:$fwdport;#g' \
    -e 's#proxy_pass http://127\.0\.0\.1:\$fwdport\$is_args\$args;#proxy_pass http://127.0.0.1:$fwdport$request_uri;#g' \
    -e 's#proxy_pass http://127\.0\.0\.1:\$fwdport;#proxy_pass http://127.0.0.1:$fwdport$request_uri;#g' \
    -e 's#proxy_pass http://127\.0\.0\.1:\$fwdport/\$fwdpath\$is_args\$args;#proxy_pass http://127.0.0.1:$fwdport$request_uri;#g' \
    "$snippet" 2>/dev/null || true
  sed -i '/strip dynamic port prefix before upstream/d; /^[[:space:]]*rewrite[[:space:]]\+\^\/\\d\+\/(.*)\$[[:space:]]\+\/\$1[[:space:]]\+break;[[:space:]]*$/d' "$snippet" 2>/dev/null || true
  if [[ "$had_dynamic" != "1" ]]; then
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
  if ($http_content_type ~* "grpc") {
    grpc_pass grpc://127.0.0.1:$fwdport;
    break;
  }
  if ($http_upgrade ~* "(WEBSOCKET|WS)") {
    proxy_pass http://127.0.0.1:$fwdport$request_uri;
    break;
  }
  if ($request_method ~* ^(PUT|POST|GET)$) {
    proxy_pass http://127.0.0.1:$fwdport$request_uri;
    break;
  }
}
EOF
  fi
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      [[ -n "$backup" && -f "$backup" ]] && cp -a "$backup" "$snippet" 2>/dev/null || true
      warn "nginx dynamic x-ui proxy update failed validation; restored $snippet"
      [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
      return 1
    fi
  fi
  [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
}

xui_allow_public_inbound_port() {
  local port="$1" protocol="${2:-tcp}"
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw allow "${port}/${protocol}" >/dev/null 2>&1 || true
}

xui_public_preset_port_rules() {
  local db
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  sqlite3 -separator $'\t' -readonly "$db" "
    SELECT DISTINCT
           CASE
             WHEN json_valid(stream_settings)=1
                  AND CAST(COALESCE(json_extract(stream_settings,'$.externalProxy[0].port'),0) AS INTEGER) > 0
               THEN CAST(json_extract(stream_settings,'$.externalProxy[0].port') AS INTEGER)
             ELSE port
           END,
           CASE
             WHEN protocol IN ('hysteria','hysteria2') THEN 'udp'
             ELSE 'tcp'
           END
    FROM inbounds
    WHERE enable=1
      AND port > 0
$(xui_preset_inbound_filter_sql);
  " 2>/dev/null || true
}

xui_open_public_preset_ports() {
  local rows port protocol
  rows="$(xui_public_preset_port_rules)"
  while IFS=$'\t' read -r port protocol; do
    [[ -n "$port" ]] || continue
    xui_allow_public_inbound_port "$port" "${protocol:-tcp}"
  done <<<"$rows"
}

xui_install_3dp_reference_presets() {
  local db="$1" public_domain="$2" private_key="$3" public_key="$4" emoji_flag="$5"
  local certificate_file="$6" key_file="$7"
  local sniffing settings stream port sni tag remark password auth obfs_password reality_index preset_profile

  [[ -f "$db" ]] || return 0
  preset_profile="${XUI_PRESET_PROFILE:-stable}"
  [[ "$preset_profile" == "stable" || "$preset_profile" == "extended" ]] || upm_die "XUI_PRESET_PROFILE must be stable or extended"

  xui_3dp_random_port() {
    local candidate
    candidate="$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000 + 10000 ))"
    xui_next_free_inbound_port "$db" "$candidate"
  }

  xui_3dp_insert() {
    local protocol="$1"
    port="$2"
    remark="$3"
    settings="$4"
    stream="$5"
    tag="inbound-${port}"
    sqlite3 "$db" "
      INSERT INTO inbounds
        (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
      VALUES
        (1, 0, 0, 0, $(sql_quote "$remark"), 1, 0, '', $port, $(sql_quote "$protocol"), $(sql_quote "$settings"), $(sql_quote "$stream"), $(sql_quote "$tag"), $(sql_quote "$sniffing"));
    "
  }

  xui_3dp_remark() {
    local name="$1"
    if [[ -n "$emoji_flag" ]]; then
      printf '%s %s' "$emoji_flag" "$name"
    else
      printf '%s' "$name"
    fi
  }

  xui_3dp_reality_stream() {
    local network="$1" decoy="$2" inbound_port="$3" transport_json="$4"
    jq -cn \
      --arg network "$network" \
      --arg decoy "$decoy" \
      --arg publicDomain "$public_domain" \
      --arg privateKey "$private_key" \
      --arg publicKey "$public_key" \
      --arg sid1 "$(openssl rand -hex 4)" \
      --arg sid2 "$(openssl rand -hex 4)" \
      --argjson inboundPort "$inbound_port" \
      --argjson transport "$transport_json" \
      '{
        network:$network,
        security:"reality",
        externalProxy:[{forceTls:"same",dest:$publicDomain,port:$inboundPort,remark:""}],
        sockopt:{acceptProxyProtocol:true},
        realitySettings:{
          show:false,
          xver:0,
          target:($decoy + ":443"),
          dest:($decoy + ":443"),
          serverNames:[$decoy],
          privateKey:$privateKey,
          shortIds:[$sid1,$sid2],
          settings:{publicKey:$publicKey,fingerprint:"random",serverName:"",spiderX:"/"}
        }
      } + $transport'
  }

  sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":true}'

  # Called only after destructive fresh x-ui installation. Replace upstream four-profile seed.
  sqlite3 "$db" "DELETE FROM client_traffics; DELETE FROM inbounds;"

  settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
  reality_index=0
  if [[ "$preset_profile" == "extended" ]]; then
    for sni in ya.ru vk.com ok.ru ozon.ru; do
      reality_index=$((reality_index + 1))
      port="$(xui_3dp_random_port)"
      stream="$(xui_3dp_reality_stream tcp "$sni" "$port" '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')"
      xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-tcp-reality-${reality_index}")" "$settings" "$stream"
    done
  else
    sni="${REALITY_DEST:-www.microsoft.com}"
    reality_index=$((reality_index + 1))
    port="$(xui_3dp_random_port)"
    stream="$(xui_3dp_reality_stream tcp "$sni" "$port" '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')"
    xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-tcp-reality-${reality_index}")" "$settings" "$stream"
  fi

  port="$(xui_3dp_random_port)"
  if [[ "$preset_profile" == "extended" ]]; then
    sni="avito.ru"
    stream="$(xui_3dp_reality_stream xhttp "$sni" "$port" '{"xhttpSettings":{"host":"avito.ru","path":"/","mode":"auto","noSSEHeader":false,"scMaxBufferedPosts":30,"scMaxEachPostBytes":"1000000","scStreamUpServerSecs":"20-80","xPaddingBytes":"100-1000"}}')"
    xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-xhttp-reality")" "$settings" "$stream"
  else
    stream="$(jq -cn --arg publicDomain "$public_domain" --argjson port "$port" '{
      network:"xhttp",
      security:"none",
      externalProxy:[{forceTls:"tls",dest:$publicDomain,port:443,remark:""}],
      xhttpSettings:{host:$publicDomain,path:("/" + ($port|tostring) + "/"),mode:"packet-up",headers:{},noSSEHeader:false,scMaxBufferedPosts:30,scMaxEachPostBytes:"1000000",xPaddingBytes:"100-1000"},
      sockopt:{acceptProxyProtocol:false}
    }')"
    xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-xhttp")" "$settings" "$stream"
  fi

  if [[ "$preset_profile" == "extended" ]]; then
    port="$(xui_3dp_random_port)"
    # gosuslugi.ru geoblocks many hosting/datacenter IPs. Keep the gRPC REALITY
    # preset on a reachable TLS 1.3 decoy and allow an operator override.
    sni="${REALITY_GRPC_DECOY:-dzen.ru}"
    stream="$(xui_3dp_reality_stream grpc "$sni" "$port" "$(jq -cn --arg authority "$sni" '{grpcSettings:{serviceName:"myservice",authority:$authority,multiMode:false}}')")"
    xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-grpc-reality")" "$settings" "$stream"
  fi

  port="$(xui_3dp_random_port)"
  # vless-ws is fronted on public 443 by the nginx domain vhost (www upstream),
  # which terminates TLS for $public_domain and path-proxies "/<port>/" to this
  # backend (xui_ensure_nginx_dynamic_proxy). forceTls:"tls" makes the published
  # link use TLS+SNI=$public_domain. nginx forwards plain HTTP upgrade to the
  # backend (no PROXY header at the http hop), so acceptProxyProtocol is false.
  stream="$(jq -cn --arg publicDomain "$public_domain" --argjson port "$port" '{
    network:"ws",
    security:"none",
    externalProxy:[{forceTls:"tls",dest:$publicDomain,port:443,remark:""}],
    wsSettings:{host:$publicDomain,path:("/" + ($port|tostring) + "/"),acceptProxyProtocol:false,heartbeatPeriod:0,headers:{}}
  }')"
  xui_3dp_insert vless "$port" "$(xui_3dp_remark "vless-ws")" "$settings" "$stream"

  settings='{"clients":[],"fallbacks":[]}'
  if [[ "$preset_profile" == "extended" ]]; then
    # shadowsocks has no SNI/TLS, so it cannot share nginx's 443. It keeps a
    # stable dedicated port (default 8388, override SS_PUBLIC_PORT) that you open
    # once in the provider firewall/security group.
    port="$(xui_next_free_inbound_port "$db" "${SS_PUBLIC_PORT:-8388}")"
    password="$(openssl rand -base64 32 | tr -d '\n')"
    settings="$(jq -cn --arg password "$password" '{clients:[],ivCheck:false,method:"2022-blake3-aes-256-gcm",network:"tcp",password:$password}')"
    stream="$(jq -cn --arg publicDomain "$public_domain" --argjson port "$port" '{
      network:"tcp",
      security:"none",
      externalProxy:[{forceTls:"none",dest:$publicDomain,port:$port,remark:""}],
      tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}
    }')"
    xui_3dp_insert shadowsocks "$port" "$(xui_3dp_remark "shadowsocks")" "$settings" "$stream"

    # hysteria2 is QUIC/UDP and cannot share nginx's TCP 443. In xui-only mode it
    # binds public UDP 443. Unified installs override HY2_PUBLIC_PORT because
    # nginx owns TCP 443 in all-in-one mode.
    port="${HY2_PUBLIC_PORT:-443}"
    if [[ "$port" != "443" ]]; then
      port="$(xui_next_free_inbound_port "$db" "$port")"
    fi
    auth="$(openssl rand -hex 16)"
    obfs_password="$(openssl rand -hex 8)"
    settings="$(jq -cn --arg auth "$auth" '{clients:[],version:2}')"
    stream="$(jq -cn \
      --arg publicDomain "$public_domain" \
      --arg certificateFile "$certificate_file" \
      --arg keyFile "$key_file" \
      --arg auth "$auth" \
      --arg obfsPassword "$obfs_password" \
      --argjson port "$port" \
      '{
        network:"hysteria",
        security:"tls",
        externalProxy:[{forceTls:"tls",dest:$publicDomain,port:$port,remark:""}],
        finalmask:{udp:[{type:"salamander",settings:{password:$obfsPassword}}]},
        hysteriaSettings:{auth:$auth,masquerade:{content:"",dir:"",headers:{},insecure:true,rewriteHost:false,statusCode:0,type:"proxy",url:"https://google.com"},udpIdleTimeout:60,version:2},
        tlsSettings:{serverName:$publicDomain,alpn:["h3"],certificates:[{buildChain:false,certificateFile:$certificateFile,keyFile:$keyFile,oneTimeLoading:false,usage:"encipherment"}],cipherSuites:"",disableSystemRoot:false,echForceQuery:"none",echServerKeys:"",enableSessionResumption:false,maxVersion:"1.3",minVersion:"1.2",rejectUnknownSni:false}
      }')"
    xui_3dp_insert hysteria "$port" "$(xui_3dp_remark "hysteria2")" "$settings" "$stream"

    port="$(xui_3dp_random_port)"
    sni="kinopoisk.ru"
    settings='{"clients":[],"fallbacks":[]}'
    stream="$(xui_3dp_reality_stream tcp "$sni" "$port" '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')"
    xui_3dp_insert trojan "$port" "$(xui_3dp_remark "trojan-tcp-reality")" "$settings" "$stream"
  else
    port="$(xui_3dp_random_port)"
    stream="$(jq -cn --arg publicDomain "$public_domain" --arg serviceName "${port}/trojan-grpc" '{
      network:"grpc",
      security:"none",
      externalProxy:[{forceTls:"tls",dest:$publicDomain,port:443,remark:""}],
      grpcSettings:{serviceName:$serviceName,authority:$publicDomain,multiMode:false}
    }')"
    xui_3dp_insert trojan "$port" "$(xui_3dp_remark "trojan-grpc")" "$settings" "$stream"
  fi
}

xui_v3_warp_base_public_domain() {
  local db="$1" fallback="$2" domain
  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  domain="$(sqlite3 -readonly "$db" "
    SELECT COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),'')
    FROM inbounds
    WHERE json_valid(stream_settings)=1
      AND COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),'') <> ''
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
    ORDER BY id
    LIMIT 1;
  " 2>/dev/null || true)"
  printf '%s\n' "$domain"
}

xui_v3_warp_clone_port() {
  local db="$1" tag="$2" candidate="$3" existing
  existing="$(sqlite3 -readonly "$db" "SELECT COALESCE(port,0) FROM inbounds WHERE tag=$(sql_quote "$tag") LIMIT 1;" 2>/dev/null || true)"
  if [[ "$existing" =~ ^[0-9]+$ && "$existing" -gt 0 ]]; then
    printf '%s\n' "$existing"
  else
    xui_next_free_inbound_port "$db" "$candidate"
  fi
}

xui_v3_warp_clone_insert_or_update() {
  local db="$1" base_id="$2" tag="$3" remark="$4" new_port="$5" new_stream="$6" report_file="$7"
  local mirror_id user_id up down total expiry_time protocol settings sniffing
  mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$tag") LIMIT 1;" 2>/dev/null || true)"
  user_id="$(sqlite3 -readonly "$db" "SELECT COALESCE(user_id,1) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 1)"
  up="$(sqlite3 -readonly "$db" "SELECT COALESCE(up,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 0)"
  down="$(sqlite3 -readonly "$db" "SELECT COALESCE(down,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 0)"
  total="$(sqlite3 -readonly "$db" "SELECT COALESCE(total,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 0)"
  expiry_time="$(sqlite3 -readonly "$db" "SELECT COALESCE(expiry_time,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 0)"
  protocol="$(sqlite3 -readonly "$db" "SELECT protocol FROM inbounds WHERE id=$base_id;" 2>/dev/null || true)"
  settings="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(settings)=1 THEN json(settings) ELSE '' END FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo '')"
  sniffing="$(sqlite3 -readonly "$db" "SELECT sniffing FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo '{}')"
  if ! jq -e . >/dev/null 2>&1 <<<"$settings"; then
    case "$protocol" in
      vless) settings='{"clients":[],"decryption":"none","fallbacks":[]}' ;;
      trojan) settings='{"clients":[],"fallbacks":[]}' ;;
      shadowsocks) settings='{"clients":[],"ivCheck":false,"method":"2022-blake3-aes-256-gcm","network":"tcp","password":""}' ;;
      hysteria|hysteria2) settings='{"clients":[],"version":2}' ;;
      *) settings='{"clients":[]}' ;;
    esac
  fi
  settings="$(jq -c '.clients = []' <<<"$settings")"

  if [[ -n "$mirror_id" ]]; then
    sqlite3 "$db" "
      UPDATE inbounds
      SET remark=$(sql_quote "$remark"),
          enable=1,
          listen='',
          port=$new_port,
          protocol=$(sql_quote "$protocol"),
          settings=$(sql_quote "$settings"),
          stream_settings=$(sql_quote "$new_stream"),
          sniffing=$(sql_quote "$sniffing")
      WHERE id=$mirror_id;
    "
    [[ -n "$report_file" ]] && printf 'warp-preset=%s id=%s action=updated\n' "$tag" "$mirror_id" >> "$report_file"
  else
    sqlite3 "$db" "
      INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
      VALUES ($user_id, $up, $down, $total, $(sql_quote "$remark"), 1, $expiry_time, '', $new_port, $(sql_quote "$protocol"), $(sql_quote "$settings"), $(sql_quote "$new_stream"), $(sql_quote "$tag"), $(sql_quote "$sniffing"));
    "
    mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$tag") LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$report_file" ]] && printf 'warp-preset=%s id=%s action=created\n' "$tag" "$mirror_id" >> "$report_file"
  fi
}

xui_v3_warp_insert_or_update_raw() {
  local db="$1" tag="$2" remark="$3" protocol="$4" port="$5" settings="$6" stream="$7" sniffing="$8" report_file="$9"
  local mirror_id
  mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$tag") LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "$mirror_id" ]]; then
    sqlite3 "$db" "
      UPDATE inbounds
      SET remark=$(sql_quote "$remark"),
          enable=1,
          listen='',
          port=$port,
          protocol=$(sql_quote "$protocol"),
          settings=$(sql_quote "$settings"),
          stream_settings=$(sql_quote "$stream"),
          sniffing=$(sql_quote "$sniffing")
      WHERE id=$mirror_id;
    "
    [[ -n "$report_file" ]] && printf 'warp-preset=%s id=%s action=updated\n' "$tag" "$mirror_id" >> "$report_file"
  else
    sqlite3 "$db" "
      INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
      VALUES (1, 0, 0, 0, $(sql_quote "$remark"), 1, 0, '', $port, $(sql_quote "$protocol"), $(sql_quote "$settings"), $(sql_quote "$stream"), $(sql_quote "$tag"), $(sql_quote "$sniffing"));
    "
    mirror_id="$(sqlite3 -readonly "$db" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$tag") LIMIT 1;" 2>/dev/null || true)"
    [[ -n "$report_file" ]] && printf 'warp-preset=%s id=%s action=created\n' "$tag" "$mirror_id" >> "$report_file"
  fi
}

xui_json_or_empty_object() {
  local value="${1:-}"
  if jq -e . >/dev/null 2>&1 <<<"$value"; then
    printf '%s\n' "$value"
  else
    printf '{}\n'
  fi
}

xui_ensure_v3_manual_warp_presets() {
  local db="$1" public_domain="${2:-}" report_file="${3:-}"
  local base_id base_port base_stream new_port new_stream decoy tag emoji_flag reality_template reality_settings
  [[ -f "$db" ]] || return 0
  [[ "${XUI_CREATE_WARP_PRESETS:-0}" == "1" ]] || return 0
  public_domain="$(xui_v3_warp_base_public_domain "$db" "$public_domain")"
  [[ "$public_domain" =~ ^[A-Za-z0-9.-]+$ ]] || upm_die "Cannot create WARP presets: --domain is required or no externalProxy.dest exists"
  emoji_flag="${XUI_EMOJI_FLAG:-🇫🇮}"
  xui_v3_warp_remark() {
    local name="$1"
    if [[ -n "$emoji_flag" ]]; then
      printf '%s %s' "$emoji_flag" "$name"
    else
      printf '%s' "$name"
    fi
  }
  sqlite3 "$db" "
    UPDATE inbounds
    SET stream_settings=json_set(stream_settings, '$.externalProxy[0].remark', '')
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy')='array'
      AND (
        COALESCE(tag,'') LIKE 'upm-v3-warp-%'
        OR COALESCE(tag,'') LIKE '%-warp'
        OR lower(COALESCE(remark,'')) LIKE '%warp%'
      );
  "

  tag="upm-v3-warp-reality"
  base_id="$(sqlite3 -readonly "$db" "
    SELECT id FROM inbounds
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='tcp'
      AND json_extract(stream_settings,'$.security')='reality'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
    ORDER BY id LIMIT 1;
  " 2>/dev/null || true)"
  if [[ -n "$base_id" ]]; then
    base_port="$(sqlite3 -readonly "$db" "SELECT COALESCE(port,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 30000)"
    base_stream="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo '{}')"
    base_stream="$(xui_json_or_empty_object "$base_stream")"
    new_port="$(xui_v3_warp_clone_port "$db" "$tag" "$((base_port + 1000))")"
    decoy="${REALITY_WARP_TCP_DECOY:-www.microsoft.com}"
    new_stream="$(jq -c --arg publicDomain "$public_domain" --arg decoy "$decoy" '
      .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"same",dest:"",port:443,remark:""}] end)
      | .externalProxy[0].forceTls = "same"
      | .externalProxy[0].dest = $publicDomain
      | .externalProxy[0].port = 443
      | .externalProxy[0].remark = ""
      | .sockopt = (.sockopt // {})
      | .sockopt.acceptProxyProtocol = true
      | .realitySettings = (.realitySettings // {})
      | .realitySettings.target = ($decoy + ":443")
      | .realitySettings.dest = ($decoy + ":443")
      | .realitySettings.serverNames = [$decoy]
      | .realitySettings.settings = (.realitySettings.settings // {})
      | .realitySettings.settings.serverName = ""
    ' <<<"$base_stream")"
    [[ -n "$new_stream" ]] || upm_die "Cannot build WARP REALITY stream settings from inbound id=$base_id"
    xui_v3_warp_clone_insert_or_update "$db" "$base_id" "$tag" "$(xui_v3_warp_remark "vless-reality-warp")" "$new_port" "$new_stream" "$report_file"
  else
    warn "Cannot create WARP REALITY preset: base vless tcp reality inbound not found"
  fi

  tag="upm-v3-warp-xhttp"
  base_id="$(sqlite3 -readonly "$db" "
    SELECT id FROM inbounds
    WHERE protocol='vless'
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='xhttp'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
    ORDER BY id LIMIT 1;
  " 2>/dev/null || true)"
  if [[ -n "$base_id" ]]; then
    base_port="$(sqlite3 -readonly "$db" "SELECT COALESCE(port,0) FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo 30000)"
    base_stream="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo '{}')"
    base_stream="$(xui_json_or_empty_object "$base_stream")"
    new_port="$(xui_v3_warp_clone_port "$db" "$tag" "$((base_port + 1000))")"
    decoy="${REALITY_WARP_XHTTP_DECOY:-www.cloudflare.com}"
    reality_template="$(sqlite3 -readonly "$db" "
      SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END
      FROM inbounds
      WHERE protocol='vless'
        AND json_valid(stream_settings)=1
        AND json_extract(stream_settings,'$.network')='tcp'
        AND json_extract(stream_settings,'$.security')='reality'
        AND COALESCE(tag,'') NOT LIKE '%-warp'
        AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      ORDER BY id LIMIT 1;
    " 2>/dev/null || echo '{}')"
    reality_template="$(xui_json_or_empty_object "$reality_template")"
    reality_settings="$(jq -c '.realitySettings // {}' <<<"$reality_template")"
    [[ "$reality_settings" != "{}" ]] || upm_die "Cannot create WARP XHTTP preset: no base REALITY settings found"
    new_stream="$(jq -c --arg publicDomain "$public_domain" --arg decoy "$decoy" --argjson realitySettings "$reality_settings" '
      .security = "reality"
      | .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"same",dest:"",port:443,remark:""}] end)
      | .externalProxy[0].forceTls = "same"
      | .externalProxy[0].dest = $publicDomain
      | .externalProxy[0].port = 443
      | .externalProxy[0].remark = ""
      | .sockopt = (.sockopt // {})
      | .sockopt.acceptProxyProtocol = true
      | .xhttpSettings = (.xhttpSettings // {})
      | .xhttpSettings.host = $decoy
      | .realitySettings = $realitySettings
      | .realitySettings.target = ($decoy + ":443")
      | .realitySettings.dest = ($decoy + ":443")
      | .realitySettings.serverNames = [$decoy]
      | .realitySettings.settings = (.realitySettings.settings // {})
      | .realitySettings.settings.serverName = ""
    ' <<<"$base_stream")"
    [[ -n "$new_stream" ]] || upm_die "Cannot build WARP XHTTP stream settings from inbound id=$base_id"
    xui_v3_warp_clone_insert_or_update "$db" "$base_id" "$tag" "$(xui_v3_warp_remark "vless-xhttp-warp")" "$new_port" "$new_stream" "$report_file"
  else
    warn "Cannot create WARP XHTTP preset: base vless xhttp inbound not found"
  fi

  tag="upm-v3-warp-hysteria2"
  base_id="$(sqlite3 -readonly "$db" "
    SELECT id FROM inbounds
    WHERE protocol IN ('hysteria','hysteria2')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='hysteria'
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
    ORDER BY id LIMIT 1;
  " 2>/dev/null || true)"
  if [[ -n "$base_id" ]]; then
    base_stream="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END FROM inbounds WHERE id=$base_id;" 2>/dev/null || echo '{}')"
    base_stream="$(xui_json_or_empty_object "$base_stream")"
    new_port="$(xui_v3_warp_clone_port "$db" "$tag" "${HY2_WARP_PUBLIC_PORT:-24443}")"
    new_stream="$(jq -c --arg publicDomain "$public_domain" --argjson publicPort "$new_port" '
      .externalProxy = (if ((.externalProxy // []) | length) > 0 then .externalProxy else [{forceTls:"tls",dest:"",port:$publicPort,remark:""}] end)
      | .externalProxy[0].forceTls = "tls"
      | .externalProxy[0].dest = $publicDomain
      | .externalProxy[0].port = $publicPort
      | .externalProxy[0].remark = ""
      | .tlsSettings = (.tlsSettings // {})
      | .tlsSettings.serverName = $publicDomain
    ' <<<"$base_stream")"
    [[ -n "$new_stream" ]] || upm_die "Cannot build WARP Hysteria2 stream settings from inbound id=$base_id"
    xui_v3_warp_clone_insert_or_update "$db" "$base_id" "$tag" "$(xui_v3_warp_remark "hysteria2-warp")" "$new_port" "$new_stream" "$report_file"
  else
    new_port="$(xui_v3_warp_clone_port "$db" "$tag" "${HY2_WARP_PUBLIC_PORT:-24443}")"
    local auth obfs_password settings sniffing certificate_file key_file
    auth="$(openssl rand -hex 16)"
    obfs_password="$(openssl rand -hex 8)"
    settings='{"clients":[],"version":2}'
    sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":true}'
    certificate_file="/root/cert/${public_domain}/fullchain.pem"
    key_file="/root/cert/${public_domain}/privkey.pem"
    new_stream="$(jq -cn \
      --arg publicDomain "$public_domain" \
      --arg certificateFile "$certificate_file" \
      --arg keyFile "$key_file" \
      --arg auth "$auth" \
      --arg obfsPassword "$obfs_password" \
      --argjson port "$new_port" \
      '{
        network:"hysteria",
        security:"tls",
        externalProxy:[{forceTls:"tls",dest:$publicDomain,port:$port,remark:""}],
        finalmask:{udp:[{type:"salamander",settings:{password:$obfsPassword}}]},
        hysteriaSettings:{auth:$auth,masquerade:{content:"",dir:"",headers:{},insecure:true,rewriteHost:false,statusCode:0,type:"proxy",url:"https://google.com"},udpIdleTimeout:60,version:2},
        tlsSettings:{serverName:$publicDomain,alpn:["h3"],certificates:[{buildChain:false,certificateFile:$certificateFile,keyFile:$keyFile,oneTimeLoading:false,usage:"encipherment"}],cipherSuites:"",disableSystemRoot:false,echForceQuery:"none",echServerKeys:"",enableSessionResumption:false,maxVersion:"1.3",minVersion:"1.2",rejectUnknownSni:false}
      }')"
    xui_v3_warp_insert_or_update_raw "$db" "$tag" "$(xui_v3_warp_remark "hysteria2-warp")" hysteria "$new_port" "$settings" "$new_stream" "$sniffing" "$report_file"
  fi
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
    def mirror_service($path):
      ($newPort|tostring) + "/" + (clean_path($path) | sub("-warp$"; "")) + "-warp";
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
      | .grpcSettings.serviceName = mirror_service(.grpcSettings.serviceName)
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
  [[ "${XUI_CREATE_WARP_INBOUNDS:-0}" == "1" ]] || return 0

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
    settings="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(settings)=1 THEN json(settings) ELSE '{\"clients\":[]}' END FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
    stream_settings="$(sqlite3 -readonly "$db" "SELECT CASE WHEN json_valid(stream_settings)=1 THEN json(stream_settings) ELSE '{}' END FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
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
