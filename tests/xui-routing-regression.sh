#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
db="$tmp_dir/x-ui.db"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"

for cmd in sqlite3 jq openssl; do
  command_exists "$cmd" || die "$cmd is required"
done

sqlite3 "$db" <<'SQL'
CREATE TABLE inbounds (
  id INTEGER PRIMARY KEY,
  remark TEXT,
  protocol TEXT,
  port INTEGER,
  enable INTEGER,
  stream_settings TEXT
);
SQL

reality_stream="$(jq -cn '{
  network:"tcp",
  security:"reality",
  realitySettings:{
    privateKey:"private-key",
    settings:{publicKey:"public-key"}
  }
}')"
vless_grpc_tls="$(jq -cn '{
  network:"grpc",
  security:"tls",
  externalProxy:[{forceTls:"tls",dest:"vpn.example.com",port:26013,remark:""}],
  grpcSettings:{serviceName:"grpc-old",authority:"vpn.example.com",multiMode:false},
  tlsSettings:{serverName:"vpn.example.com"}
}')"
trojan_grpc_tls="$(jq -cn '{
  network:"grpc",
  security:"tls",
  externalProxy:[{forceTls:"tls",dest:"vpn.example.com",port:41798,remark:""}],
  grpcSettings:{serviceName:"trojan-grpc",authority:"vpn.example.com",multiMode:false},
  tlsSettings:{serverName:"vpn.example.com"}
}')"

sqlite3 "$db" "
  INSERT INTO inbounds VALUES (1, 'vless-tcp-reality-ya.ru', 'vless', 11366, 1, $(sql_quote "$reality_stream"));
  INSERT INTO inbounds VALUES (2, 'vless-grpc-tls', 'vless', 26013, 1, $(sql_quote "$vless_grpc_tls"));
  INSERT INTO inbounds VALUES (3, 'trojan-grpc-tls', 'trojan', 41798, 1, $(sql_quote "$trojan_grpc_tls"));
"

XUI_DB="$db" xui_restore_reference_vless_grpc_reality_inbounds
XUI_DB="$db" xui_disable_experimental_trojan_grpc_presets

[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.security') FROM inbounds WHERE id=2;")" == "reality" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.realitySettings.serverNames[0]') FROM inbounds WHERE id=2;")" == "dzen.ru" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.grpcSettings.authority') FROM inbounds WHERE id=2;")" == "dzen.ru" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT remark FROM inbounds WHERE id=2;")" == "vless-grpc-reality" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(stream_settings,'$.security') FROM inbounds WHERE id=3;")" == "tls" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT remark FROM inbounds WHERE id=3;")" == "trojan-grpc-tls" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT enable FROM inbounds WHERE id=3;")" == "0" ]]

printf 'xui-routing regression OK\n'
