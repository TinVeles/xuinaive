#!/usr/bin/env bash
#
# add-inbounds.sh
# ---------------
# ADDITIVELY add one preset inbound to an existing x-ui install WITHOUT wiping
# the current inbounds/clients (unlike install.sh which does DELETE FROM inbounds):
#
#   * vless-ws       (VLESS over WebSocket + TLS on its own port)
#
# It reuses the server's existing public domain + TLS certificate, picks free
# ports, opens ufw, seeds client UUIDs via generate-profiles.sh, and restarts x-ui.
#
# Safe + idempotent: skips an inbound whose remark already exists; backs up the DB.
#
# Usage:
#   sudo bash add-inbounds.sh
#   sudo DRY_RUN=1 bash add-inbounds.sh           # preview, no writes
#
set -euo pipefail

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
ok()   { printf '%sOK%s   %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%sWARN%s %s\n' "$c_yel" "$c_rst" "$*"; }
die()  { printf '%sBAD%s  %s\n' "$c_red" "$c_rst" "$*"; exit 1; }
info() { printf 'info %s\n' "$*"; }

[[ $EUID -eq 0 ]]            || die "run as root"
command -v sqlite3 >/dev/null || die "sqlite3 not found"
command -v jq      >/dev/null || die "jq not found"
command -v openssl >/dev/null || die "openssl not found"
[[ -f "$DB" ]]              || die "x-ui DB not found: $DB"

sqlr() { sqlite3 -readonly "$DB" "$1"; }
sqlw() { [[ "$DRY_RUN" == "1" ]] && { warn "DRY_RUN sql: ${1//$'\n'/ }"; return 0; }; sqlite3 "$DB" "$1"; }
q()    { printf "'%s'" "${1//\'/\'\'}"; }

# --- discover existing server identity -------------------------------------
PUBLIC_DOMAIN="$(sqlr "
  SELECT json_extract(stream_settings,'\$.externalProxy[0].dest')
  FROM inbounds
  WHERE json_extract(stream_settings,'\$.externalProxy[0].dest') IS NOT NULL
    AND json_extract(stream_settings,'\$.externalProxy[0].dest') <> ''
  LIMIT 1;")"
[[ -n "$PUBLIC_DOMAIN" ]] || die "could not read public domain from existing inbounds"

# emoji/flag prefix from an existing remark (e.g. "🇩🇪")
SAMPLE_REMARK="$(sqlr "SELECT remark FROM inbounds WHERE remark LIKE '%vless-tcp-reality%' LIMIT 1;")"
EMOJI="${SAMPLE_REMARK%% *}"
[[ "$EMOJI" == "$SAMPLE_REMARK" || -z "$EMOJI" ]] && EMOJI="🏳"

# TLS cert/key reused from an existing TLS inbound (hysteria2) so vless-ws can be
# masked as real HTTPS for ${PUBLIC_DOMAIN}. Override with WS_CERT / WS_KEY.
read -r CERT_FILE KEY_FILE < <(sqlr "
  SELECT COALESCE(json_extract(stream_settings,'\$.tlsSettings.certificates[0].certificateFile'),'') || ' ' ||
         COALESCE(json_extract(stream_settings,'\$.tlsSettings.certificates[0].keyFile'),'')
  FROM inbounds
  WHERE json_extract(stream_settings,'\$.tlsSettings.certificates[0].certificateFile') IS NOT NULL
  LIMIT 1;")
CERT_FILE="${WS_CERT:-$CERT_FILE}"
KEY_FILE="${WS_KEY:-$KEY_FILE}"

SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":true}'

info "public domain : $PUBLIC_DOMAIN"
info "flag          : $EMOJI"

# --- helpers ---------------------------------------------------------------
RESERVED="22 25 53 80 110 143 443 465 587 993 995 2053 2083 2087 2096 3000 54321 7443 8080 8081 8443 9443 9445"
free_port() {
  local p
  while :; do
    p=$(( RANDOM % 40000 + 10000 ))
    [[ " $RESERVED " == *" $p "* ]] && continue
    [[ "$(sqlr "SELECT COUNT(*) FROM inbounds WHERE port=$p;")" != "0" ]] && continue
    ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q . && continue
    printf '%s\n' "$p"; return
  done
}
remark_exists() { [[ "$(sqlr "SELECT COUNT(*) FROM inbounds WHERE remark=$(q "$1");")" != "0" ]]; }

insert_inbound() {
  local protocol="$1" port="$2" remark="$3" settings="$4" stream="$5" tag="inbound-$2"
  sqlw "
    INSERT INTO inbounds
      (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
    VALUES
      (1,0,0,0,$(q "$remark"),1,0,'',$port,$(q "$protocol"),$(q "$settings"),$(q "$stream"),$(q "$tag"),$(q "$SNIFFING"));"
  command -v ufw >/dev/null && [[ "$DRY_RUN" != "1" ]] && ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  ok "added $remark on port $port/tcp"
}

# --- backup ----------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  cp -a "$DB" "${DB}.bak.$(date +%Y%m%d%H%M%S)"
  info "DB backed up"
fi

ADDED=0

# === 1) vless-ws + TLS (masked as real HTTPS) ==============================
WS_REMARK="${EMOJI} vless-ws-tls"
if remark_exists "$WS_REMARK"; then
  warn "skip: '$WS_REMARK' already exists"
elif [[ -z "$CERT_FILE" || -z "$KEY_FILE" ]]; then
  warn "skip vless-ws-tls: no TLS cert found (set WS_CERT=/path/fullchain.pem WS_KEY=/path/privkey.pem)"
elif [[ "$DRY_RUN" != "1" && ( ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ) ]]; then
  warn "skip vless-ws-tls: cert/key file missing on disk ($CERT_FILE / $KEY_FILE)"
else
  ok "vless-ws-tls cert: $CERT_FILE"
  port="$(free_port)"
  # random path so it does not collide / look generic
  wspath="/$(openssl rand -hex 4)"
  settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
  stream="$(jq -cn \
    --arg dom "$PUBLIC_DOMAIN" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" \
    --arg path "$wspath" --argjson port "$port" '{
    network:"ws",
    security:"tls",
    externalProxy:[{forceTls:"tls",dest:$dom,port:$port,remark:""}],
    wsSettings:{host:$dom,path:$path,acceptProxyProtocol:false,heartbeatPeriod:0,headers:{}},
    tlsSettings:{
      serverName:$dom,
      alpn:["http/1.1"],
      certificates:[{buildChain:false,certificateFile:$cert,keyFile:$key,oneTimeLoading:false,usage:"encipherment"}],
      minVersion:"1.2",maxVersion:"1.3",
      cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,
      enableSessionResumption:false,settings:{allowInsecure:false,fingerprint:"chrome"}
    }
  }')"
  insert_inbound vless "$port" "$WS_REMARK" "$settings" "$stream"
  ADDED=1
fi

# --- seed clients + apply --------------------------------------------------
if (( ADDED )) && [[ "$DRY_RUN" != "1" ]]; then
  command -v ufw >/dev/null && ufw reload >/dev/null 2>&1 || true
  info "restarting x-ui..."
  systemctl restart x-ui; sleep 2
  systemctl is-active --quiet x-ui && ok "x-ui active" || die "x-ui failed; journalctl -u x-ui -n 50"

  info "seeding client UUIDs + rebuilding subscription (generate-profiles.sh)..."
  if [[ -x "$SCRIPT_DIR/generate-profiles.sh" || -f "$SCRIPT_DIR/generate-profiles.sh" ]]; then
    bash "$SCRIPT_DIR/generate-profiles.sh" --xui-only --yes || warn "generate-profiles.sh returned non-zero; run it manually"
  else
    warn "generate-profiles.sh not found next to this script; run it manually to seed clients"
  fi
fi

printf '\n=== result ===\n'
sqlite3 "$DB" "SELECT id, port, protocol,
       json_extract(stream_settings,'\$.network') AS net,
       json_extract(stream_settings,'\$.security') AS sec,
       remark
       FROM inbounds WHERE remark=$(q "$WS_REMARK");" 2>/dev/null || true

printf '\nNext: refresh subscription in your client (v2rayN: Update subscription), then test.\n'
