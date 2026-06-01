#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
db="$tmp_dir/x-ui.db"
stream_conf="$tmp_dir/stream.conf"
upstream_conf="$tmp_dir/upm-xui-reality.conf"
ufw_log="$tmp_dir/ufw.log"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"

for cmd in sqlite3 jq openssl; do
  command_exists "$cmd" || die "$cmd is required"
done

sqlite3 "$db" <<'SQL'
CREATE TABLE inbounds (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER,
  up INTEGER,
  down INTEGER,
  total INTEGER,
  remark TEXT,
  enable INTEGER,
  expiry_time INTEGER,
  listen TEXT,
  port INTEGER,
  protocol TEXT,
  settings TEXT,
  stream_settings TEXT,
  tag TEXT,
  sniffing TEXT
);
CREATE TABLE client_traffics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  inbound_id INTEGER
);
SQL

cat > "$stream_conf" <<'EOF'
map $ssl_preread_server_name $sni_name {
    hostnames;
    vpn.example.com www;
    default xray;
}

upstream xray {
    server 127.0.0.1:8443;
}
EOF

ufw() {
  printf '%s\n' "$*" >> "$ufw_log"
}

install_presets() {
  local hy2_port="${1:-443}"
  HY2_PUBLIC_PORT="$hy2_port" \
    xui_install_3dp_reference_presets \
      "$db" vpn.example.com private-key public-key flag \
      /etc/x-ui/server.crt /etc/x-ui/server.key
  sqlite3 "$db" "
    UPDATE inbounds
    SET stream_settings=json_set(stream_settings,'$.sockopt.acceptProxyProtocol',json('false'))
    WHERE id=(SELECT id FROM inbounds WHERE remark LIKE '%vless-tcp-reality-1' LIMIT 1);

    UPDATE inbounds
    SET stream_settings=json_set(
      stream_settings,
      '$.externalProxy[0].port', port,
      '$.wsSettings.path', '/',
      '$.wsSettings.acceptProxyProtocol', json('true')
    )
    WHERE remark LIKE '%vless-ws';
  "
  XUI_DB="$db" xui_normalize_reference_preset_external_proxy_ports
}

install_presets 443

[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM inbounds;')" == "10" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds WHERE remark GLOB '*vless-tcp-reality-[1-4]';")" == "4" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds WHERE json_extract(stream_settings,'$.security')='reality' AND json_extract(stream_settings,'$.sockopt.acceptProxyProtocol')=1;")" == "7" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds WHERE json_extract(stream_settings,'$.security')='reality' AND json_extract(stream_settings,'$.externalProxy[0].port')=443;")" == "7" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.externalProxy[0].port') FROM inbounds WHERE remark LIKE '%vless-ws';")" == "443" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.wsSettings.path') FROM inbounds WHERE remark LIKE '%vless-ws';")" =~ ^/[0-9]+/$ ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.wsSettings.acceptProxyProtocol') FROM inbounds WHERE remark LIKE '%vless-ws';")" == "0" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT port || ':' || json_extract(stream_settings,'$.externalProxy[0].port') FROM inbounds WHERE remark LIKE '%shadowsocks-tcp';")" == "8388:8388" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT port || ':' || json_extract(stream_settings,'$.externalProxy[0].port') FROM inbounds WHERE remark LIKE '%hysteria2-udp';")" == "443:443" ]]

XUI_DB="$db" \
NGINX_STREAM_CONF="$stream_conf" \
NGINX_XUI_REALITY_UPSTREAM_CONF="$upstream_conf" \
  xui_ensure_nginx_reality_sni_routes

[[ "$(grep -c '^upstream upm_xui_reality_' "$upstream_conf")" == "7" ]]
[[ "$(grep -c 'BEGIN unified-proxy-manager x-ui reality routes' "$stream_conf")" == "1" ]]
grep -Eq 'ya\.ru[[:space:]]+upm_xui_reality_[0-9]+;' "$stream_conf"
grep -Eq 'kinopoisk\.ru[[:space:]]+upm_xui_reality_[0-9]+;' "$stream_conf"
grep -q 'vpn.example.com www;' "$stream_conf"

cp "$stream_conf" "$tmp_dir/stream.before-nginx-failure.conf"
cp "$upstream_conf" "$tmp_dir/upstreams.before-nginx-failure.conf"
sqlite3 "$db" "
  UPDATE inbounds
  SET stream_settings=json_set(stream_settings,'$.realitySettings.serverNames',json_array('mail.ru'))
  WHERE remark LIKE '%vless-tcp-reality-2';
"
nginx() {
  return 1
}
if XUI_DB="$db" \
   NGINX_STREAM_CONF="$stream_conf" \
   NGINX_XUI_REALITY_UPSTREAM_CONF="$upstream_conf" \
     xui_ensure_nginx_reality_sni_routes; then
  die "failed nginx validation should reject REALITY route update"
fi
unset -f nginx
cmp "$tmp_dir/stream.before-nginx-failure.conf" "$stream_conf"
cmp "$tmp_dir/upstreams.before-nginx-failure.conf" "$upstream_conf"
sqlite3 "$db" "
  UPDATE inbounds
  SET stream_settings=json_set(stream_settings,'$.realitySettings.serverNames',json_array('vk.com'))
  WHERE remark LIKE '%vless-tcp-reality-2';
"

cp "$stream_conf" "$tmp_dir/stream.before-duplicate.conf"
sqlite3 "$db" "
  UPDATE inbounds
  SET stream_settings=json_set(stream_settings,'$.realitySettings.serverNames',json_array('ya.ru'))
  WHERE remark LIKE '%vless-tcp-reality-2';
"
if XUI_DB="$db" \
   NGINX_STREAM_CONF="$stream_conf" \
   NGINX_XUI_REALITY_UPSTREAM_CONF="$upstream_conf" \
     xui_ensure_nginx_reality_sni_routes; then
  die "duplicate REALITY SNI should be rejected"
fi
cmp "$tmp_dir/stream.before-duplicate.conf" "$stream_conf"

install_presets 24443
[[ "$(sqlite3 -readonly "$db" "SELECT port || ':' || json_extract(stream_settings,'$.externalProxy[0].port') FROM inbounds WHERE remark LIKE '%hysteria2-udp';")" == "24443:24443" ]]

: > "$ufw_log"
XUI_DB="$db" xui_open_public_preset_ports
grep -q '^allow 443/tcp$' "$ufw_log"
grep -q '^allow 8388/tcp$' "$ufw_log"
grep -q '^allow 24443/udp$' "$ufw_log"

printf 'xui-routing 443 regression OK\n'
