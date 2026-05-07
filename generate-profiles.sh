#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

COUNT="${COUNT:-15}"
PREFIX="${PREFIX:-auto}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
NH_CONFIG="${NH_CONFIG:-/opt/panel-naive-hy2/panel/data/config.json}"
CADDYFILE="${CADDYFILE:-/etc/caddy-nh/Caddyfile}"
HYSTERIA_CONFIG="${HYSTERIA_CONFIG:-/etc/hysteria/config.yaml}"
NH_SUBSCRIPTION_DIR="${NH_SUBSCRIPTION_DIR:-/opt/panel-naive-hy2/subscriptions}"
NH_SUBSCRIPTION_TOKEN_FILE="${NH_SUBSCRIPTION_TOKEN_FILE:-/etc/nh-panel/subscription-token}"
NH_SUBSCRIPTION_NGINX="${NH_SUBSCRIPTION_NGINX:-1}"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-domain:openai.com,domain:chatgpt.com,domain:oaistatic.com,domain:oaiusercontent.com,domain:anthropic.com,domain:claude.ai,domain:gemini.google.com,domain:generativelanguage.googleapis.com,domain:ai.google.dev,domain:notebooklm.google.com,domain:notebooklm.google}"
CREATE_XUI="${CREATE_XUI:-1}"
CREATE_NH="${CREATE_NH:-1}"
RELOAD_SERVICES="${RELOAD_SERVICES:-1}"
ASSUME_YES=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { printf '%s\n' "${BLUE}INFO:${NC} $*"; }
ok() { printf '%s\n' "${GREEN}OK:${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${NC} $*"; }
err() { printf '%s\n' "${RED}ERROR:${NC} $*" >&2; }
die() { err "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage:
  sudo bash generate-profiles.sh --yes
  sudo bash generate-profiles.sh --count 15 --prefix auto --yes
  sudo bash generate-profiles.sh --xui-only --yes
  sudo bash generate-profiles.sh --nh-only --yes

Creates:
  x-ui:  COUNT shared-email clients on every preset inbound,
         plus one WARP clone inbound per preset inbound with COUNT clients.
  N+H:   COUNT NaiveProxy profiles and COUNT Hysteria2 profiles.
         Subscription files are written to ${NH_SUBSCRIPTION_DIR}.

WARP variants:
  outbound tag: ${WARP_OUTBOUND_TAG}
  local proxy:  ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
  AI domains:   ${WARP_AI_DOMAINS}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:-}"; shift 2 ;;
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --xui-db) XUI_DB="${2:-}"; shift 2 ;;
    --nh-config) NH_CONFIG="${2:-}"; shift 2 ;;
    --caddyfile) CADDYFILE="${2:-}"; shift 2 ;;
    --hysteria-config) HYSTERIA_CONFIG="${2:-}"; shift 2 ;;
    --subscription-dir) NH_SUBSCRIPTION_DIR="${2:-}"; shift 2 ;;
    --no-nginx-subscription) NH_SUBSCRIPTION_NGINX=0; shift ;;
    --warp-host) WARP_PROXY_HOST="${2:-}"; shift 2 ;;
    --warp-port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --warp-outbound-tag) WARP_OUTBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-ai-domains) WARP_AI_DOMAINS="${2:-}"; shift 2 ;;
    --xui-only) CREATE_XUI=1; CREATE_NH=0; shift ;;
    --nh-only) CREATE_XUI=0; CREATE_NH=1; shift ;;
    --no-reload) RELOAD_SERVICES=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]] || die "--count must be a positive number"
[[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--warp-port must be numeric"
[[ "$PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--prefix may contain only A-Z, a-z, 0-9, dot, underscore, and dash"

for cmd in node openssl; do
  command_exists "$cmd" || die "$cmd is required"
done
if [[ "$CREATE_XUI" == "1" ]]; then
  command_exists sqlite3 || die "sqlite3 is required for x-ui profile generation"
  command_exists jq || die "jq is required for x-ui profile generation"
  [[ -f "$XUI_DB" ]] || die "x-ui database not found: $XUI_DB"
fi

backup_dir="/opt/unified-proxy-manager/backups/profiles-$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$XUI_DB" "$NH_CONFIG" "$CADDYFILE" "$HYSTERIA_CONFIG" /etc/nginx/snippets/nh-subscriptions.conf; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
ok "Backup directory: $backup_dir"

rand_password() {
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20
}

uuid_value() {
  if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
    /usr/local/x-ui/bin/xray-linux-amd64 uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

sql_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

xui_next_free_port() {
  local candidate="$1"
  [[ "$candidate" =~ ^[0-9]+$ && "$candidate" -gt 0 ]] || { printf '0\n'; return 0; }
  while [[ "$(sqlite3 -readonly "$XUI_DB" "SELECT COUNT(*) FROM inbounds WHERE port=$candidate;" 2>/dev/null || echo 0)" != "0" ]]; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

xui_client_json() {
  local inbound_id="$1" protocol="$2" email="$3" now="$4" password uid client_json
  if [[ "$protocol" == "trojan" ]]; then
    password="$(rand_password)"
    jq -cn \
      --arg email "$email" \
      --arg subId "$email" \
      --arg password "$password" \
      --arg now "$now" \
      '{comment:"", created_at:($now|tonumber), email:$email, enable:true, expiryTime:0, limitIp:0, password:$password, reset:0, subId:$subId, tgId:0, totalGB:0, updated_at:($now|tonumber)}'
  else
    uid="$(uuid_value | tr -d '[:space:]')"
    client_json="$(jq -cn \
      --arg email "$email" \
      --arg subId "$email" \
      --arg id "$uid" \
      --arg now "$now" \
      '{id:$id, flow:"", email:$email, limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:"", subId:$subId, reset:0, created_at:($now|tonumber), updated_at:($now|tonumber)}')"
    if sqlite3 "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id=$inbound_id;" | grep -q '"security"[[:space:]]*:[[:space:]]*"reality"'; then
      jq '.flow = "xtls-rprx-vision"' <<<"$client_json"
    else
      printf '%s\n' "$client_json"
    fi
  fi
}

xui_replace_generated_clients() {
  local inbound_id="$1" protocol="$2" mode="$3" tag="$4" report_file="$5"
  local now index email client_json clients_json settings new_settings traffic_result
  now="$(date +%s)000"
  clients_json="[]"

  for index in $(seq -w 1 "$COUNT"); do
    email="${PREFIX}-${index}"
    client_json="$(xui_client_json "$inbound_id" "$protocol" "$email" "$now")"
    clients_json="$(jq -c --argjson client "$client_json" '. + [$client]' <<<"$clients_json")"
  done

  settings="$(sqlite3 -readonly "$XUI_DB" "SELECT settings FROM inbounds WHERE id=$inbound_id;")"
  new_settings="$(jq -c --arg prefix "$PREFIX" --argjson clients "$clients_json" '
    def generated_email:
      ((.email // "") | tostring) as $email
      | ($email | startswith($prefix + "-"))
        and (($email | ltrimstr($prefix + "-")) | test("^(warp-)?[0-9]+$"));
    .clients = ((.clients // [])
      | map(select(generated_email | not))
      + $clients)
  ' <<<"$settings")"

  sqlite3 "$XUI_DB" "UPDATE inbounds SET settings=$(sql_quote "$new_settings") WHERE id=$inbound_id;"
  sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=$inbound_id AND (email GLOB $(sql_quote "${PREFIX}-[0-9]*") OR email GLOB $(sql_quote "${PREFIX}-warp-[0-9]*"));"
  for index in $(seq -w 1 "$COUNT"); do
    email="${PREFIX}-${index}"
    traffic_result="$(sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($inbound_id, 1, $(sql_quote "$email"), 0, 0, 0, 0, 0); SELECT changes();" 2>/dev/null || true)"
    if [[ "${traffic_result##*$'\n'}" != "1" ]]; then
      printf 'WARN traffic duplicate/ignored inbound=%s email=%s\n' "$inbound_id" "$email" >> "$report_file"
    fi
    printf 'inbound=%s protocol=%s tag=%s mode=%s email=%s\n' "$inbound_id" "$protocol" "${tag:-}" "$mode" "$email" >> "$report_file"
  done
}

xui_ensure_warp_inbound() {
  local base_id="$1" protocol="$2" base_tag="$3" base_remark="$4" base_port="$5" base_enable="$6"
  local existing_id warp_port warp_tag warp_remark warp_enable settings empty_settings

  warp_remark="${base_remark:-$protocol-$base_id} WARP"
  warp_tag="${base_tag:-inbound-${base_id}}-warp"
  existing_id="$(sqlite3 -readonly "$XUI_DB" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$warp_tag") OR remark=$(sql_quote "$warp_remark") LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "$existing_id" ]]; then
    printf '%s\n' "$existing_id"
    return 0
  fi

  if [[ "$base_port" =~ ^[0-9]+$ && "$base_port" -gt 0 ]]; then
    warp_port="$(xui_next_free_port "$((base_port + 10000))")"
    warp_tag="inbound-${warp_port}-warp"
    warp_enable="$base_enable"
  else
    warp_port="$base_port"
    warp_enable=0
  fi

  settings="$(sqlite3 -readonly "$XUI_DB" "SELECT settings FROM inbounds WHERE id=$base_id;")"
  empty_settings="$(jq -c '.clients = []' <<<"$settings")"
  sqlite3 "$XUI_DB" "
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
    SELECT user_id, 0, 0, total, $(sql_quote "$warp_remark"), $warp_enable, expiry_time, listen, $warp_port, protocol, $(sql_quote "$empty_settings"), stream_settings, $(sql_quote "$warp_tag"), sniffing
    FROM inbounds WHERE id=$base_id;
  "
  sqlite3 -readonly "$XUI_DB" "SELECT id FROM inbounds WHERE tag=$(sql_quote "$warp_tag") ORDER BY id DESC LIMIT 1;"
}

xui_add_clients() {
  info "Creating x-ui clients in $XUI_DB"
  local inbound_rows inbound_id protocol tag remark port enable warp_id warp_tag report_file warp_tags_file
  report_file="/etc/x-ui/generated-clients.txt"
  warp_tags_file="$(mktemp)"
  mkdir -p "$(dirname "$report_file")"
  : > "$report_file"
  sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE email GLOB $(sql_quote "${PREFIX}-[0-9]*") OR email GLOB $(sql_quote "${PREFIX}-warp-[0-9]*");"

  inbound_rows="$(sqlite3 -separator $'\t' "$XUI_DB" \
    "SELECT id, protocol, COALESCE(tag,''), COALESCE(remark,''), port, enable
     FROM inbounds
     WHERE protocol IN ('vless','trojan')
       AND COALESCE(tag,'') NOT LIKE '%-warp'
       AND lower(COALESCE(remark,'')) NOT LIKE '%warp%'
     ORDER BY id;")"
  [[ -n "$inbound_rows" ]] || die "No x-ui preset inbounds found in $XUI_DB"

  while IFS=$'\t' read -r inbound_id protocol tag remark port enable; do
    [[ -n "$inbound_id" ]] || continue

    xui_replace_generated_clients "$inbound_id" "$protocol" "direct" "$tag" "$report_file"
    warp_id="$(xui_ensure_warp_inbound "$inbound_id" "$protocol" "$tag" "$remark" "$port" "$enable")"
    warp_tag="$(sqlite3 -readonly "$XUI_DB" "SELECT COALESCE(tag,'') FROM inbounds WHERE id=$warp_id;")"
    xui_replace_generated_clients "$warp_id" "$protocol" "warp" "$warp_tag" "$report_file"
    [[ -n "$warp_tag" ]] && printf '%s\n' "$warp_tag" >> "$warp_tags_file"

    ok "x-ui base inbound ${inbound_id} + WARP inbound ${warp_id}: $COUNT shared-email clients each"
  done <<<"$inbound_rows"

  xui_apply_warp_template "$warp_tags_file"
  rm -f "$warp_tags_file"
}

xui_apply_warp_template() {
  local warp_tags_file="$1"
  local tags_json domains_json current key snippet_dir snippet_file updated
  tags_json="$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$warp_tags_file")"
  domains_json="$(printf '%s\n' "$WARP_AI_DOMAINS" \
    | tr ',' '\n' \
    | jq -Rsc 'split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique')"
  snippet_dir="/etc/x-ui"
  snippet_file="$snippet_dir/warp-generated-routing.json"
  mkdir -p "$snippet_dir"

  jq -cn \
    --arg tag "$WARP_OUTBOUND_TAG" \
    --arg host "$WARP_PROXY_HOST" \
    --argjson port "$WARP_PROXY_PORT" \
    --argjson inboundTags "$tags_json" \
    --argjson domains "$domains_json" \
    '{
      outbound: {tag:$tag, protocol:"socks", settings:{servers:[{address:$host, port:$port}]}},
      routingRule: {type:"field", inboundTag:$inboundTags, domain:$domains, outboundTag:$tag}
    }' > "$snippet_file"

  key="$(sqlite3 -readonly "$XUI_DB" "SELECT key FROM settings WHERE key IN ('xrayTemplateConfig','xrayConfig','xraySetting') LIMIT 1;" || true)"
  if [[ -z "$key" ]]; then
    key="xrayTemplateConfig"
    current='{}'
  else
    current="$(sqlite3 -readonly "$XUI_DB" "SELECT value FROM settings WHERE key=$(sql_quote "$key") LIMIT 1;" || true)"
    [[ -n "$current" ]] || current='{}'
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"$current"; then
    warn "x-ui setting $key is not valid JSON. Saved WARP routing snippet only: $snippet_file"
    return 0
  fi

  updated="$(jq -c \
    --arg tag "$WARP_OUTBOUND_TAG" \
    --arg host "$WARP_PROXY_HOST" \
    --argjson port "$WARP_PROXY_PORT" \
    --argjson inboundTags "$tags_json" \
    --argjson domains "$domains_json" '
    .outbounds = ((.outbounds // [])
      | map(select(.tag != $tag))
      + [{tag:$tag, protocol:"socks", settings:{servers:[{address:$host, port:$port}]}}])
    | .routing = (.routing // {})
    | .routing.rules = ((.routing.rules // [])
      | map(select(.outboundTag != $tag))
      + [{type:"field", inboundTag:$inboundTags, domain:$domains, outboundTag:$tag}])
  ' <<<"$current")"

  sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key=$(sql_quote "$key");"
  sqlite3 "$XUI_DB" "INSERT INTO settings (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$updated"));"
  ok "x-ui WARP outbound/routing saved in settings.$key"
  ok "WARP routing snippet saved: $snippet_file"
  ok "WARP routing scope: WARP inbounds only + AI domains only"
  ok "x-ui generated client report saved: /etc/x-ui/generated-clients.txt"
}

nh_generate() {
  info "Creating N+H NaiveProxy and Hysteria2 profiles"
  [[ -f "$NH_CONFIG" ]] || die "N+H config not found: $NH_CONFIG"

  mkdir -p "$(dirname "$NH_SUBSCRIPTION_TOKEN_FILE")"
  if [[ -s "$NH_SUBSCRIPTION_TOKEN_FILE" ]]; then
    NH_SUBSCRIPTION_TOKEN="$(tr -dc 'A-Za-z0-9._-' < "$NH_SUBSCRIPTION_TOKEN_FILE" | head -c 128)"
  else
    NH_SUBSCRIPTION_TOKEN="$(openssl rand -hex 24)"
    printf '%s\n' "$NH_SUBSCRIPTION_TOKEN" > "$NH_SUBSCRIPTION_TOKEN_FILE"
    chmod 0600 "$NH_SUBSCRIPTION_TOKEN_FILE"
  fi
  [[ -n "$NH_SUBSCRIPTION_TOKEN" ]] || die "Could not create N+H subscription token"
  chmod 0600 "$NH_SUBSCRIPTION_TOKEN_FILE" 2>/dev/null || true

  COUNT="$COUNT" PREFIX="$PREFIX" NH_CONFIG="$NH_CONFIG" CADDYFILE="$CADDYFILE" HYSTERIA_CONFIG="$HYSTERIA_CONFIG" NH_SUBSCRIPTION_DIR="$NH_SUBSCRIPTION_DIR" NH_SUBSCRIPTION_TOKEN="$NH_SUBSCRIPTION_TOKEN" SCRIPT_DIR="$SCRIPT_DIR" node <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const path = require('path');

const count = parseInt(process.env.COUNT || '15', 10);
const prefix = process.env.PREFIX || 'auto';
const cfgPath = process.env.NH_CONFIG;
const caddyfile = process.env.CADDYFILE;
const hyPath = process.env.HYSTERIA_CONFIG;
const reportPath = '/opt/panel-naive-hy2/generated-profiles.txt';
const subRoot = process.env.NH_SUBSCRIPTION_DIR || '/opt/panel-naive-hy2/subscriptions';
const subToken = process.env.NH_SUBSCRIPTION_TOKEN || 'missing-token';
const subDir = path.join(subRoot, subToken);

function pass() {
  return cp.execSync("openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20", { encoding: 'utf8', shell: '/bin/bash' }).trim();
}

const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
cfg.stack = cfg.stack || {};
cfg.stack.naive = true;
cfg.stack.hy2 = true;
cfg.naiveUsers = Array.isArray(cfg.naiveUsers) ? cfg.naiveUsers : [];
cfg.hy2Users = Array.isArray(cfg.hy2Users) ? cfg.hy2Users : [];
cfg.installed = cfg.installed !== false;
const now = new Date().toISOString();
const generatedNaive = [];
const generatedHy2 = [];
const generatedNaiveRe = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-naive-[0-9]+$`);
const generatedHy2Re = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-hy2-[0-9]+$`);

cfg.naiveUsers = cfg.naiveUsers.filter(u => !generatedNaiveRe.test(String(u.username || '')));
cfg.hy2Users = cfg.hy2Users.filter(u => !generatedHy2Re.test(String(u.username || '')));

for (let i = 1; i <= count; i += 1) {
  const n = String(i).padStart(2, '0');
  const naiveName = `${prefix}-naive-${n}`;
  const hyName = `${prefix}-hy2-${n}`;
  const naiveUser = { username: naiveName, password: pass(), createdAt: now };
  const hyUser = { username: hyName, password: pass(), createdAt: now };
  cfg.naiveUsers.push(naiveUser);
  cfg.hy2Users.push(hyUser);
  generatedNaive.push(naiveUser);
  generatedHy2.push(hyUser);
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));

if (fs.existsSync(caddyfile)) {
  let content = fs.readFileSync(caddyfile, 'utf8');
  const authLines = cfg.naiveUsers
    .map(u => `    basic_auth ${u.username} ${u.password}`)
    .join('\n');
  content = content.replace(/(forward_proxy\s*\{\n)([\s\S]*?)(\n\s*hide_ip)/, `$1${authLines}$3`);
  fs.writeFileSync(`${caddyfile}.new`, content);
  fs.renameSync(`${caddyfile}.new`, caddyfile);
}

function loadYaml() {
  const possible = [
    '/opt/panel-naive-hy2/panel/node_modules/js-yaml',
    `${process.env.SCRIPT_DIR}/components/nh-panel/upstream/panel/node_modules/js-yaml`,
    'js-yaml'
  ];
  for (const mod of possible) {
    try { return require(mod); } catch (_) {}
  }
  return null;
}

if (fs.existsSync(hyPath)) {
  const yaml = loadYaml();
  if (!yaml) {
    console.error('WARN: js-yaml not found; Hysteria2 config was not regenerated');
    process.exitCode = 2;
  } else {
    const hy = yaml.load(fs.readFileSync(hyPath, 'utf8')) || {};
    hy.auth = hy.auth || {};
    hy.auth.type = 'userpass';
    hy.auth.userpass = {};
    for (const u of cfg.hy2Users) hy.auth.userpass[u.username] = u.password;
    fs.writeFileSync(hyPath, yaml.dump(hy, { lineWidth: 120, quotingType: '"' }));
  }
}

const domain = cfg.domain || 'DOMAIN_NOT_SET';
const generatedNaiveLinks = generatedNaive.map(u => `naive+https://${u.username}:${u.password}@${domain}:443#${encodeURIComponent(u.username)}`);
const hy2UserpassAuth = u => encodeURIComponent(`${u.username}:${u.password}`);
const generatedHy2Links = generatedHy2.map(u => `hysteria2://${hy2UserpassAuth(u)}@${domain}:443?sni=${domain}&insecure=0#${encodeURIComponent(u.username)}`);
const naiveLinks = generatedNaiveLinks;
const hy2Links = generatedHy2Links;
const lines = [];
lines.push('Generated N+H profiles');
lines.push('======================');
lines.push('');
lines.push('NaiveProxy:');
for (const link of generatedNaiveLinks) lines.push(link);
lines.push('');
lines.push('Hysteria2:');
for (const link of generatedHy2Links) lines.push(link);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, lines.join('\n') + '\n', { mode: 0o600 });

function b64(s) {
  return Buffer.from(s, 'utf8').toString('base64');
}

function singBoxOutboundFromLink(link, index) {
  if (link.startsWith('naive+https://')) {
    const raw = link.slice('naive+'.length);
    const url = new URL(raw);
    return {
      type: 'naive',
      tag: `naive-${index}`,
      server: url.hostname,
      server_port: Number(url.port || 443),
      username: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password)
    };
  }
  if (link.startsWith('hysteria2://')) {
    const url = new URL(link);
    const auth = url.password
      ? `${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`
      : decodeURIComponent(url.username);
    return {
      type: 'hysteria2',
      tag: `hy2-${index}`,
      server: url.hostname,
      server_port: Number(url.port || 443),
      password: auth,
      tls: {
        enabled: true,
        server_name: url.searchParams.get('sni') || url.hostname,
        insecure: url.searchParams.get('insecure') === '1'
      }
    };
  }
  return null;
}

const allLinks = [...naiveLinks, ...hy2Links];
const singBox = {
  log: { level: 'info' },
  outbounds: allLinks.map(singBoxOutboundFromLink).filter(Boolean)
};

for (const name of ['naive.txt', 'hy2.txt', 'all.txt', 'naive.b64', 'hy2.b64', 'all.b64', 'sing-box.json']) {
  try { fs.unlinkSync(path.join(subRoot, name)); } catch (_) {}
  try { fs.unlinkSync(path.join(subDir, name)); } catch (_) {}
}
fs.mkdirSync(subDir, { recursive: true, mode: 0o755 });
fs.writeFileSync(`${subDir}/naive.txt`, naiveLinks.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/hy2.txt`, hy2Links.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/all.txt`, allLinks.join('\n') + '\n', { mode: 0o644 });
fs.writeFileSync(`${subDir}/naive.b64`, b64(naiveLinks.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/hy2.b64`, b64(hy2Links.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/all.b64`, b64(allLinks.join('\n')), { mode: 0o644 });
fs.writeFileSync(`${subDir}/sing-box.json`, JSON.stringify(singBox, null, 2) + '\n', { mode: 0o644 });
if (generatedNaive.length !== count || generatedHy2.length !== count) {
  throw new Error(`Generated count mismatch: naive=${generatedNaive.length}, hy2=${generatedHy2.length}, expected=${count}`);
}
NODE

  if [[ -f "$CADDYFILE" ]]; then
    if command_exists caddy-nh; then
      caddy-nh validate --config "$CADDYFILE" >/dev/null || die "Generated Caddyfile is invalid"
    elif command_exists caddy; then
      caddy validate --config "$CADDYFILE" >/dev/null || die "Generated Caddyfile is invalid"
    fi
  fi
  ok "N+H config updated: $COUNT NaiveProxy + $COUNT Hysteria2 profiles"
  ok "N+H generated links saved: /opt/panel-naive-hy2/generated-profiles.txt"
  ok "N+H subscriptions saved: ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  configure_nginx_subscription
}

configure_nginx_subscription() {
  [[ "$NH_SUBSCRIPTION_NGINX" == "1" ]] || return 0
  command_exists nginx || { warn "nginx is not installed; subscription files were created locally only"; return 0; }
  [[ -d /etc/nginx/conf.d ]] || { warn "/etc/nginx/conf.d not found; subscription files were created locally only"; return 0; }

  mkdir -p /etc/nginx/snippets
  cat > /etc/nginx/snippets/nh-subscriptions.conf <<EOF
location ^~ /sub/ {
    alias ${NH_SUBSCRIPTION_DIR%/}/;
    default_type text/plain;
    autoindex off;
    types {
        application/json json;
        text/plain txt b64;
    }
    add_header Cache-Control "no-store";
    add_header X-Content-Type-Options "nosniff" always;
}
EOF

  local conf="/etc/nginx/conf.d/nh-subscriptions.conf"
  local panel_conf="/etc/nginx/sites-available/panel-naive-hy2"
  if [[ -f "$panel_conf" ]]; then
    if ! grep -q 'include /etc/nginx/snippets/nh-subscriptions.conf;' "$panel_conf"; then
      sed -i '/location \/ {/i\    include /etc/nginx/snippets/nh-subscriptions.conf;' "$panel_conf"
    fi
  fi

  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<'EOF'
server {
    listen 127.0.0.1:18081;
    server_name _;
    include /etc/nginx/snippets/nh-subscriptions.conf;
}
EOF
  fi

  if nginx -T 2>/dev/null | grep -q 'include /etc/nginx/snippets/nh-subscriptions.conf'; then
    ok "nginx subscription location is configured"
  else
    warn "nginx snippet was written, but no public server includes it. Files are still available locally in ${NH_SUBSCRIPTION_DIR%/}/$NH_SUBSCRIPTION_TOKEN"
  fi
  nginx -t >/dev/null && systemctl reload nginx 2>/dev/null || warn "nginx reload failed"
}

if [[ "$CREATE_XUI" == "1" ]]; then
  xui_add_clients
fi

if [[ "$CREATE_NH" == "1" ]]; then
  nh_generate
fi

if [[ "$RELOAD_SERVICES" == "1" ]]; then
  info "Reloading services"
  if [[ "$CREATE_XUI" == "1" ]] && command_exists systemctl; then
    systemctl restart x-ui || warn "x-ui restart failed"
  fi
  if [[ "$CREATE_NH" == "1" ]] && command_exists systemctl; then
    if systemctl is-active --quiet caddy-nh 2>/dev/null; then
      systemctl reload caddy-nh 2>/dev/null || systemctl restart caddy-nh || warn "caddy-nh reload failed"
    fi
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
      systemctl restart hysteria-server || warn "hysteria-server restart failed"
    fi
    if systemctl is-active --quiet panel-naive-hy2 2>/dev/null; then
      systemctl restart panel-naive-hy2 || warn "panel-naive-hy2 restart failed"
    fi
  fi
fi

cat <<EOF

Profile generation complete
---------------------------
x-ui:
  direct clients: ${COUNT} shared email/subId clients on every preset inbound
  WARP inbounds: one WARP clone per preset inbound
  WARP clients: ${COUNT} shared email/subId clients on every WARP inbound
  WARP outbound: ${WARP_OUTBOUND_TAG}
  WARP proxy: ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}
  WARP routed domains: ${WARP_AI_DOMAINS}
  WARP snippet: /etc/x-ui/warp-generated-routing.json
  x-ui report: /etc/x-ui/generated-clients.txt

N+H:
  NaiveProxy profiles: ${COUNT}
  Hysteria2 profiles: ${COUNT}
  links: /opt/panel-naive-hy2/generated-profiles.txt
  subscriptions: ${NH_SUBSCRIPTION_DIR%/}/${NH_SUBSCRIPTION_TOKEN:-TOKEN_NOT_SET}

Backup:
  ${backup_dir}
EOF
