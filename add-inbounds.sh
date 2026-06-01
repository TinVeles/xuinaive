#!/usr/bin/env bash
#
# add-inbounds.sh
# ---------------
# ADDITIVELY add two preset inbounds to an existing x-ui install WITHOUT wiping
# the current inbounds/clients (unlike install.sh which does DELETE FROM inbounds):
#
#   * vless-ws            (VLESS over WebSocket, plain — sits on its own port)
#   * trojan-grpc-reality (Trojan over gRPC with REALITY)
#
# It reuses the server's existing public domain + REALITY key pair, picks free
# ports, opens ufw, seeds client UUIDs via generate-profiles.sh, and restarts x-ui.
#
# Safe + idempotent: skips an inbound whose remark already exists; backs up the DB.
#
# Usage:
#   sudo bash add-inbounds.sh
#   sudo DRY_RUN=1 bash add-inbounds.sh           # preview, no writes
#   sudo TROJAN_GRPC_DECOY=mail.ru bash add-inbounds.sh
#
set -euo pipefail

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

read -r PRIV PUB < <(sqlr "
  SELECT json_extract(stream_settings,'\$.realitySettings.privateKey') || ' ' ||
         json_extract(stream_settings,'\$.realitySettings.settings.publicKey')
  FROM inbounds
  WHERE json_extract(stream_settings,'\$.security')='reality'
  LIMIT 1;")
[[ -n "$PRIV" && -n "$PUB" ]] || die "could not read REALITY key pair from existing inbounds"

# emoji/flag prefix from an existing remark (e.g. "🇩🇪")
SAMPLE_REMARK="$(sqlr "SELECT remark FROM inbounds WHERE remark LIKE '%vless-tcp-reality%' LIMIT 1;")"
EMOJI="${SAMPLE_REMARK%% *}"
[[ "$EMOJI" == "$SAMPLE_REMARK" || -z "$EMOJI" ]] && EMOJI="🏳"

SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":true}'

info "public domain : $PUBLIC_DOMAIN"
info "reality pubkey: $PUB"
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
decoy_ok() { timeout 6 bash -c "echo | openssl s_client -connect ${1}:443 -servername ${1} -tls1_3 2>/dev/null | grep -q CONNECTED"; }
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

# === 1) vless-ws (plain WebSocket) =========================================
WS_REMARK="${EMOJI} vless-ws"
if remark_exists "$WS_REMARK"; then
  warn "skip: '$WS_REMARK' already exists"
else
  port="$(free_port)"
  settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
  stream="$(jq -cn --arg dom "$PUBLIC_DOMAIN" --argjson port "$port" '{
    network:"ws",
    security:"none",
    externalProxy:[{forceTls:"none",dest:$dom,port:$port,remark:""}],
    wsSettings:{host:$dom,path:"/",acceptProxyProtocol:false,heartbeatPeriod:0,headers:{}}
  }')"
  insert_inbound vless "$port" "$WS_REMARK" "$settings" "$stream"
  ADDED=1
fi

# === 2) trojan-grpc-reality ================================================
TG_REMARK="${EMOJI} trojan-grpc-reality"
if remark_exists "$TG_REMARK"; then
  warn "skip: '$TG_REMARK' already exists"
else
  # pick a reachable decoy not already used by another inbound
  decoy="${TROJAN_GRPC_DECOY:-}"
  if [[ -z "$decoy" ]]; then
    for cand in mail.ru www.tbank.ru store.steampowered.com www.microsoft.com www.cloudflare.com; do
      [[ "$(sqlr "SELECT 1 FROM inbounds WHERE json_extract(stream_settings,'\$.realitySettings.serverNames[0]')='$cand' LIMIT 1;")" == "1" ]] && continue
      decoy_ok "$cand" && { decoy="$cand"; break; }
    done
  fi
  [[ -n "$decoy" ]] || die "no reachable decoy for trojan-grpc; set TROJAN_GRPC_DECOY=<domain>"
  ok "trojan-grpc decoy: $decoy"

  port="$(free_port)"
  sid1="$(openssl rand -hex 4)"; sid2="$(openssl rand -hex 4)"
  settings='{"clients":[],"fallbacks":[]}'
  stream="$(jq -cn \
    --arg dom "$PUBLIC_DOMAIN" --arg decoy "$decoy" \
    --arg priv "$PRIV" --arg pub "$PUB" \
    --arg sid1 "$sid1" --arg sid2 "$sid2" --argjson port "$port" '{
    network:"grpc",
    security:"reality",
    externalProxy:[{forceTls:"same",dest:$dom,port:$port,remark:""}],
    realitySettings:{
      show:false,xver:0,
      target:($decoy+":443"),dest:($decoy+":443"),
      serverNames:[$decoy],
      privateKey:$priv,shortIds:[$sid1,$sid2],
      settings:{publicKey:$pub,fingerprint:"random",serverName:"",spiderX:"/"}
    },
    grpcSettings:{serviceName:"trojangrpc",authority:$decoy,multiMode:false}
  }')"
  insert_inbound trojan "$port" "$TG_REMARK" "$settings" "$stream"
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
    bash "$SCRIPT_DIR/generate-profiles.sh" || warn "generate-profiles.sh returned non-zero; run it manually"
  else
    warn "generate-profiles.sh not found next to this script; run it manually to seed clients"
  fi
fi

printf '\n=== result ===\n'
sqlite3 "$DB" "SELECT id, port, protocol,
       json_extract(stream_settings,'\$.network') AS net,
       json_extract(stream_settings,'\$.security') AS sec,
       remark
       FROM inbounds WHERE remark IN ($(q "$WS_REMARK"),$(q "$TG_REMARK"));" 2>/dev/null || true

printf '\nNext: refresh subscription in your client (v2rayN: Update subscription), then test.\n'
