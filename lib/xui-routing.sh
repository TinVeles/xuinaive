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

xui_normalize_reference_preset_external_proxy_ports() {
  local db updated
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  updated="$(sqlite3 "$db" "
    UPDATE inbounds
    SET stream_settings=json_set(stream_settings, '$.externalProxy[0].port', port)
    WHERE json_valid(stream_settings)=1
      AND json_type(stream_settings, '$.externalProxy[0]')='object'
      AND CAST(COALESCE(json_extract(stream_settings, '$.externalProxy[0].port'), 0) AS INTEGER) != port
      AND COALESCE(tag,'') NOT LIKE '%-warp'
      AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
      AND (
        lower(COALESCE(remark,'')) LIKE '%vless-tcp-reality-%'
        OR lower(COALESCE(remark,'')) LIKE '%vless-xhttp-reality%'
        OR lower(COALESCE(remark,'')) LIKE '%vless-grpc%'
        OR lower(COALESCE(remark,'')) LIKE '%vless-ws%'
        OR lower(COALESCE(remark,'')) LIKE '%shadowsocks-tcp%'
        OR lower(COALESCE(remark,'')) LIKE '%hysteria2-udp%'
        OR lower(COALESCE(remark,'')) LIKE '%trojan-tcp-reality%'
        OR lower(COALESCE(remark,'')) LIKE '%trojan-grpc%'
      );

    SELECT changes();
  " 2>/dev/null || true)"
  updated="${updated##*$'\n'}"
  if [[ "$updated" =~ ^[0-9]+$ && "$updated" -gt 0 ]]; then
    printf 'INFO: Normalized reference preset public port(s): %s\n' "$updated"
  fi
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
    stream_settings="$(sqlite3 -readonly "$db" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" 2>/dev/null || echo '{}')"
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

xui_normalize_direct_grpc_tls_inbounds() {
  local db rows inbound_id remark public_domain stream_settings certificate_file key_file new_remark new_stream updated=0
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0

  rows="$(sqlite3 -separator $'\t' -readonly "$db" "
    SELECT id,
           COALESCE(remark,''),
           COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),''),
           stream_settings
    FROM inbounds
    WHERE protocol IN ('vless','trojan')
      AND json_valid(stream_settings)=1
      AND json_extract(stream_settings,'$.network')='grpc'
      AND json_extract(stream_settings,'$.security')='reality'
      AND CAST(COALESCE(json_extract(stream_settings,'$.externalProxy[0].port'),0) AS INTEGER)=port
      AND COALESCE(json_extract(stream_settings,'$.externalProxy[0].dest'),'') <> ''
    ORDER BY id;
  " 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0

  while IFS=$'\t' read -r inbound_id remark public_domain stream_settings; do
    [[ -n "$inbound_id" && -n "$public_domain" ]] || continue
    certificate_file="/root/cert/${public_domain}/fullchain.pem"
    key_file="/root/cert/${public_domain}/privkey.pem"
    if [[ ! -f "$certificate_file" || ! -f "$key_file" ]]; then
      IFS=$'\t' read -r certificate_file key_file < <(sqlite3 -separator $'\t' -readonly "$db" "
        SELECT COALESCE(json_extract(stream_settings,'$.tlsSettings.certificates[0].certificateFile'),''),
               COALESCE(json_extract(stream_settings,'$.tlsSettings.certificates[0].keyFile'),'')
        FROM inbounds
        WHERE json_valid(stream_settings)=1
          AND COALESCE(json_extract(stream_settings,'$.tlsSettings.certificates[0].certificateFile'),'') <> ''
          AND COALESCE(json_extract(stream_settings,'$.tlsSettings.certificates[0].keyFile'),'') <> ''
        LIMIT 1;
      " 2>/dev/null || true)
    fi
    certificate_file="${certificate_file%$'\r'}"
    key_file="${key_file%$'\r'}"
    if [[ ! -f "$certificate_file" || ! -f "$key_file" ]]; then
      warn "Cannot convert direct gRPC REALITY inbound id=$inbound_id to TLS: certificate for $public_domain not found"
      continue
    fi

    new_remark="${remark//grpc-reality/grpc-tls}"
    new_stream="$(jq -c \
      --arg domain "$public_domain" \
      --arg cert "$certificate_file" \
      --arg key "$key_file" '
      .security = "tls"
      | del(.realitySettings)
      | .externalProxy[0].forceTls = "tls"
      | .grpcSettings = (.grpcSettings // {})
      | .grpcSettings.authority = $domain
      | .tlsSettings = {
          serverName:$domain,
          alpn:["h2"],
          certificates:[{
            buildChain:false,
            certificateFile:$cert,
            keyFile:$key,
            oneTimeLoading:false,
            usage:"encipherment"
          }],
          cipherSuites:"",
          disableSystemRoot:false,
          echForceQuery:"none",
          echServerKeys:"",
          enableSessionResumption:false,
          maxVersion:"1.3",
          minVersion:"1.2",
          rejectUnknownSni:false
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
    printf 'INFO: Converted direct gRPC REALITY inbound(s) to TLS: %s\n' "$updated"
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

xui_ensure_nginx_reality_sni_routes() {
  local db stream_conf backup tmp_stream sni_list
  db="$(xui_db_path)"
  stream_conf="${NGINX_STREAM_CONF:-/etc/nginx/stream-enabled/stream.conf}"
  [[ -f "$db" && -f "$stream_conf" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  sni_list="$(sqlite3 -readonly "$db" "
    WITH reality_inbounds AS (
      SELECT stream_settings
      FROM inbounds
      WHERE enable=1
        AND protocol='vless'
        AND json_valid(stream_settings)=1
        AND json_extract(stream_settings,'$.network')='tcp'
        AND json_extract(stream_settings,'$.security')='reality'
    ),
    names AS (
      SELECT json_extract(stream_settings,'$.realitySettings.settings.serverName') AS name
      FROM reality_inbounds
      UNION
      SELECT value AS name
      FROM reality_inbounds,
           json_each(COALESCE(json_extract(stream_settings,'$.realitySettings.serverNames'),'[]'))
    )
    SELECT DISTINCT trim(name)
    FROM names
    WHERE trim(COALESCE(name,'')) <> '';
  " 2>/dev/null || true)"
  [[ -n "$sni_list" ]] || return 0
  grep -q 'map[[:space:]]\+\$ssl_preread_server_name[[:space:]]\+\$sni_name' "$stream_conf" 2>/dev/null || return 0

  backup="$(mktemp)"
  cp -a "$stream_conf" "$backup" 2>/dev/null || backup=""
  tmp_stream="$(mktemp)"
  awk -v snis="$sni_list" '
    BEGIN {
      n = split(snis, raw, "\n")
      for (i = 1; i <= n; i++) {
        if (raw[i] != "") route[raw[i]] = 1
      }
      in_map = 0
      inserted = 0
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
    function print_routes(    name) {
      if (inserted) return
      for (name in route) {
        printf "    %-32s xray;\n", name
        seen[name] = 1
      }
      inserted = 1
    }
    $0 ~ /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name[[:space:]]*\{/ {
      in_map = 1
      print
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
      if (candidate in route) next
      if (candidate != "" && seen[candidate]++) next
    }
    { print }
  ' "$stream_conf" > "$tmp_stream" || {
    rm -f "$tmp_stream"
    [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
    return 1
  }
  mv -f "$tmp_stream" "$stream_conf"

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    else
      [[ -n "$backup" && -f "$backup" ]] && cp -a "$backup" "$stream_conf" 2>/dev/null || true
      warn "nginx Reality SNI stream route update failed validation; restored $stream_conf"
      [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
      return 1
    fi
  fi
  [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"
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

xui_open_public_preset_ports() {
  local db rows port protocol
  db="$(xui_db_path)"
  [[ -f "$db" ]] || return 0
  rows="$(sqlite3 -separator $'\t' -readonly "$db" "
    SELECT port,
           CASE
             WHEN protocol IN ('hysteria','hysteria2') THEN 'udp'
             ELSE 'tcp'
           END
    FROM inbounds
    WHERE enable=1
      AND port > 0
$(xui_preset_inbound_filter_sql);
  " 2>/dev/null || true)"
  while IFS=$'\t' read -r port protocol; do
    [[ -n "$port" ]] || continue
    xui_allow_public_inbound_port "$port" "${protocol:-tcp}"
  done <<<"$rows"
}

xui_install_3dp_reference_presets() {
  local db="$1" public_domain="$2" private_key="$3" public_key="$4" emoji_flag="$5"
  local certificate_file="$6" key_file="$7"
  local sniffing settings stream port sni tag remark password auth obfs_password

  [[ -f "$db" ]] || return 0

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
  for sni in ya.ru vk.com ok.ru ozon.ru; do
    port="$(xui_3dp_random_port)"
    stream="$(xui_3dp_reality_stream tcp "$sni" "$port" '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')"
    xui_3dp_insert vless "$port" "${emoji_flag} vless-tcp-reality-${sni}" "$settings" "$stream"
  done

  port="$(xui_3dp_random_port)"
  sni="avito.ru"
  stream="$(xui_3dp_reality_stream xhttp "$sni" "$port" '{"xhttpSettings":{"host":"avito.ru","path":"/","mode":"auto","noSSEHeader":false,"scMaxBufferedPosts":30,"scMaxEachPostBytes":"1000000","scStreamUpServerSecs":"20-80","xPaddingBytes":"100-1000"}}')"
  xui_3dp_insert vless "$port" "${emoji_flag} vless-xhttp-reality" "$settings" "$stream"

  port="$(xui_3dp_random_port)"
  stream="$(jq -cn \
    --arg publicDomain "$public_domain" \
    --arg certificateFile "$certificate_file" \
    --arg keyFile "$key_file" \
    --arg serviceName "grpc-$(openssl rand -hex 6)" \
    --argjson port "$port" \
    '{
      network:"grpc",
      security:"tls",
      externalProxy:[{forceTls:"tls",dest:$publicDomain,port:$port,remark:""}],
      grpcSettings:{serviceName:$serviceName,authority:$publicDomain,multiMode:false},
      tlsSettings:{
        serverName:$publicDomain,
        alpn:["h2"],
        certificates:[{buildChain:false,certificateFile:$certificateFile,keyFile:$keyFile,oneTimeLoading:false,usage:"encipherment"}],
        cipherSuites:"",
        disableSystemRoot:false,
        echForceQuery:"none",
        echServerKeys:"",
        enableSessionResumption:false,
        maxVersion:"1.3",
        minVersion:"1.2",
        rejectUnknownSni:false
      }
    }')"
  xui_3dp_insert vless "$port" "${emoji_flag} vless-grpc-tls" "$settings" "$stream"

  port="$(xui_3dp_random_port)"
  stream="$(jq -cn --arg publicDomain "$public_domain" --argjson port "$port" '{
    network:"ws",
    security:"none",
    externalProxy:[{forceTls:"none",dest:$publicDomain,port:$port,remark:""}],
    wsSettings:{host:$publicDomain,path:"/",acceptProxyProtocol:false,heartbeatPeriod:0,headers:{}}
  }')"
  xui_3dp_insert vless "$port" "${emoji_flag} vless-ws" "$settings" "$stream"

  port="$(xui_3dp_random_port)"
  password="$(openssl rand -base64 32 | tr -d '\n')"
  settings="$(jq -cn --arg password "$password" '{clients:[],ivCheck:false,method:"2022-blake3-aes-256-gcm",network:"tcp",password:$password}')"
  stream="$(jq -cn --arg publicDomain "$public_domain" --argjson port "$port" '{
    network:"tcp",
    security:"none",
    externalProxy:[{forceTls:"none",dest:$publicDomain,port:$port,remark:""}],
    tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}
  }')"
  xui_3dp_insert shadowsocks "$port" "${emoji_flag} shadowsocks-tcp" "$settings" "$stream"

  port="$(xui_3dp_random_port)"
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
  xui_3dp_insert hysteria "$port" "${emoji_flag} hysteria2-udp" "$settings" "$stream"

  port="$(xui_3dp_random_port)"
  sni="kinopoisk.ru"
  settings='{"clients":[],"fallbacks":[]}'
  stream="$(xui_3dp_reality_stream tcp "$sni" "$port" '{"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}')"
  xui_3dp_insert trojan "$port" "${emoji_flag} trojan-tcp-reality" "$settings" "$stream"
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
