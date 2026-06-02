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
  tag TEXT,
  sniffing TEXT
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
  (1, 'vless-tcp-reality-ya.ru', 'vless', 11366, 1, '{"network":"tcp","security":"reality"}', 'not-json', 'bad tag', ''),
  (2, 'vless-ws', 'vless', 26591, 1, '{"network":"ws","security":"none"}', '{"clients":[{"id":"manual-uuid","security":"auto","email":"manual@example.com","enable":true}],"decryption":"none"}', 'inbound-26591', '{}'),
  (3, 'hysteria2-udp', 'hysteria', 10659, 1, '{"network":"hysteria","security":"tls"}', '{"clients":[],"version":2}', 'inbound-10659', '{}'),
  (4, 'trojan-tcp-reality', 'trojan', 45364, 1, '{"network":"tcp","security":"reality"}', '{"clients":[{"id":"manual-trojan","password":"manual-trojan","email":"manual-trojan@example.com","enable":true,"flow":"xtls-rprx-vision"}]}', 'inbound-45364', '{}'),
  (5, 'shadowsocks-tcp', 'shadowsocks', 8388, 1, '{"network":"tcp","security":"none"}', '{"clients":[{"password":"bad","email":"manual-ss@example.com","enable":true}],"method":"2022-blake3-aes-256-gcm","password":"bad"}', 'inbound-8388', '{}');
SQL

XUI_DB="$db" xui_repair_invalid_inbound_json
XUI_DB="$db" xui_sanitize_inbound_tags

[[ "$(sqlite3 "$db" "SELECT json_valid(settings) FROM inbounds WHERE id=1;")" == "1" ]]
[[ "$(sqlite3 "$db" "SELECT tag FROM inbounds WHERE id=1;")" == "inbound-11366" ]]
[[ "$(sqlite3 "$db" "SELECT json_valid(sniffing) FROM inbounds WHERE id=1;")" == "1" ]]

xui_v3_uuid() {
  printf '00000000-0000-4000-8000-%012d\n' "$((uuid_counter += 1))"
}
uuid_counter=0

XUI_DB="$db" xui_v3_replace_generated_clients "$db" 2 auto "$report"

[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM clients;')" == "2" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_inbounds;')" == "10" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_traffics;')" == "2" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=1 AND inbound_id=1;")" == "xtls-rprx-vision" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=1 AND inbound_id=2;")" == "" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_array_length(settings, '$.clients') FROM inbounds WHERE id=1;")" == "2" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_array_length(settings, '$.clients') FROM inbounds WHERE id=2;")" == "3" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=2 AND json_extract(j.value, '$.email')='manual@example.com';")" == "1" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM client_inbounds ci JOIN clients c ON c.id=ci.client_id WHERE NOT EXISTS (SELECT 1 FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=ci.inbound_id AND json_extract(j.value, '$.email')=c.email);")" == "0" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.flow') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=1 AND json_extract(j.value, '$.email')='auto-01';")" == "xtls-rprx-vision" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.flow') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=2 AND json_extract(j.value, '$.email')='auto-01';")" == "" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.flow') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=4 AND json_extract(j.value, '$.email')='manual-trojan@example.com';")" == "" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.flow') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=4 AND json_extract(j.value, '$.email')='auto-01';")" == "" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(settings, '$.password') FROM inbounds WHERE id=5;" | tr -d '\r' | base64 -d | wc -c | tr -d '[:space:]')" == "32" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.password') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=5 AND json_extract(j.value, '$.email')='manual-ss@example.com';" | tr -d '\r' | base64 -d | wc -c | tr -d '[:space:]')" == "32" ]]

sqlite3 "$db" "UPDATE client_inbounds SET flow_override='xtls-rprx-vision' WHERE client_id=1 AND inbound_id=4;"
XUI_DB="$db" xui_clear_trojan_client_flows
[[ "$(sqlite3 -readonly "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=1 AND inbound_id=4;")" == "" ]]
sqlite3 "$db" "UPDATE clients SET password='bad' WHERE id=1;"
XUI_DB="$db" xui_repair_shadowsocks_2022_keys
[[ "$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE id=1;" | tr -d '\r' | base64 -d | wc -c | tr -d '[:space:]')" == "32" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_extract(j.value, '$.password') FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=5 AND json_extract(j.value, '$.email')='auto-01';")" == "$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE id=1;")" ]]

sqlite3 "$db" <<'SQL'
INSERT INTO clients
  (email, sub_id, uuid, password, auth, flow, security, reverse, limit_ip, total_gb, expiry_time, enable, tg_id, group_name, comment, reset, created_at, updated_at)
VALUES
  ('linked@example.com', 'linked-sub', 'linked-uuid', '', '', '', 'auto', '', 0, 0, 0, 1, 0, '', '', 0, 1, 1);
INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at)
VALUES ((SELECT id FROM clients WHERE email='linked@example.com'), 2, '', 1);
INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
VALUES (2, 1, 'orphan@example.com', 0, 0, 0, 0, 0);
SQL
XUI_DB="$db" xui_v3_restore_attached_json_clients "$db"
XUI_DB="$db" xui_v3_remove_orphan_client_traffics "$db"
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=2 AND json_extract(j.value, '$.email')='linked@example.com';")" == "1" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM client_traffics WHERE email='orphan@example.com';")" == "0" ]]

old_password="$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE email='auto-01';")"
XUI_DB="$db" xui_v3_replace_generated_clients "$db" 1 auto "$report"
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM clients;')" == "2" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_inbounds;')" == "6" ]]
[[ "$(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM client_traffics;')" == "1" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT password FROM clients WHERE email='auto-01';")" == "$old_password" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT json_array_length(settings, '$.clients') FROM inbounds WHERE id=2;")" == "3" ]]
[[ "$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM inbounds i, json_each(i.settings, '$.clients') j WHERE i.id=2 AND json_extract(j.value, '$.email')='auto-02';")" == "0" ]]

printf 'xui-v3 regression OK\n'
