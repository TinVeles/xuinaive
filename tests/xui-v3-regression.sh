#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
db="$tmp_dir/x-ui.db"
report="$tmp_dir/report.txt"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"
# shellcheck source=../lib/xui-v3.sh
source "$SCRIPT_DIR/lib/xui-v3.sh"

for cmd in sqlite3 openssl; do
  command_exists "$cmd" || die "$cmd is required"
done

sqlite3 "$db" <<'SQL'
CREATE TABLE inbounds (
  id INTEGER PRIMARY KEY,
  remark TEXT,
  protocol TEXT,
  port INTEGER,
  enable INTEGER,
  stream_settings TEXT,
  settings TEXT,
  tag TEXT
);
CREATE TABLE clients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT UNIQUE,
  sub_id TEXT,
  uuid TEXT,
  password TEXT,
  auth TEXT,
  flow TEXT,
  security TEXT,
  reverse TEXT,
  limit_ip INTEGER,
  total_gb INTEGER,
  expiry_time INTEGER,
  enable INTEGER,
  tg_id INTEGER,
  group_name TEXT,
  comment TEXT,
  reset INTEGER,
  created_at INTEGER,
  updated_at INTEGER
);
CREATE TABLE client_inbounds (
  client_id INTEGER,
  inbound_id INTEGER,
  flow_override TEXT,
  created_at INTEGER,
  PRIMARY KEY (client_id, inbound_id)
);
CREATE TABLE client_traffics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  inbound_id INTEGER,
  enable INTEGER,
  email TEXT UNIQUE,
  up INTEGER,
  down INTEGER,
  expiry_time INTEGER,
  total INTEGER,
  reset INTEGER
);
INSERT INTO inbounds VALUES
  (1, 'vless-tcp-reality-ya.ru', 'vless', 11366, 1, '{"network":"tcp","security":"reality"}', '{"clients":[],"decryption":"none"}', 'inbound-11366'),
  (2, 'vless-ws', 'vless', 26591, 1, '{"network":"ws","security":"none"}', '{"clients":[],"decryption":"none"}', 'inbound-26591'),
  (3, 'hysteria2-udp', 'hysteria', 10659, 1, '{"network":"hysteria","security":"tls"}', '{"clients":[],"version":2}', 'inbound-10659');
SQL

xui_v3_uuid() {
  printf '00000000-0000-4000-8000-%012d\n' "$((uuid_counter += 1))"
}
uuid_counter=0

XUI_DB="$db" xui_v3_replace_generated_clients "$db" 2 auto "$report"

[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM clients;')" == "2" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_inbounds;')" == "6" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_traffics;')" == "2" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=1 AND inbound_id=1;")" == "xtls-rprx-vision" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=1 AND inbound_id=2;")" == "" ]]

old_password="$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE email='auto-01';")"
XUI_DB="$db" xui_v3_replace_generated_clients "$db" 1 auto "$report"
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM clients;')" == "1" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_inbounds;')" == "3" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_traffics;')" == "1" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE email='auto-01';")" == "$old_password" ]]

printf 'xui-v3 regression OK\n'
