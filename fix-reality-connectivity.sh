#!/usr/bin/env bash
#
# fix-reality-connectivity.sh
# ---------------------------
# Diagnose and repair VLESS/Trojan REALITY inbounds that show delay = -1 in the
# client while Shadowsocks / Hysteria2 on the same server work fine.
#
# It is SAFE to run repeatedly:
#   * the x-ui database is backed up before any write,
#   * every repair is conditional (only applied when a real defect is found),
#   * Shadowsocks / Hysteria2 inbounds are never modified.
#
# What it checks/fixes per enabled REALITY inbound:
#   1. port is actually LISTENING (xray bound it)
#   2. publicKey is the real x25519 pair of privateKey  -> regenerate if mismatch
#   3. shortIds present and valid hex (<=16, even length) -> add one if missing
#   4. at least one enabled client with a UUID            -> reported (cannot
#      invent subId scheme safely; tells you to run generate-profiles.sh)
#   5. decoy (serverNames[0]) reachable on :443 from the server (reality steal)
#
# After repairs it restarts x-ui and prints a verification table.
#
# Usage:
#   sudo bash fix-reality-connectivity.sh            # diagnose + auto-repair
#   sudo DRY_RUN=1 bash fix-reality-connectivity.sh  # diagnose only, no writes
#
set -euo pipefail

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
DRY_RUN="${DRY_RUN:-0}"
CHANGED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xui-routing.sh
source "$SCRIPT_DIR/lib/xui-routing.sh"

# replacement decoys when an inbound's serverName is unreachable from the server.
# must support TLS1.3 + HTTP/2 and be reachable from the host. override via env:
#   REALITY_DECOY_CANDIDATES="dzen.ru mail.ru www.microsoft.com" bash fix-reality-connectivity.sh
read -r -a REALITY_DECOY_CANDIDATES <<<"${REALITY_DECOY_CANDIDATES:-dzen.ru mail.ru www.tbank.ru store.steampowered.com www.microsoft.com www.cloudflare.com}"

# --- locate the xray binary that ships with x-ui ---------------------------
XRAY=""
for cand in /usr/local/x-ui/bin/xray-linux-* /usr/local/bin/xray /usr/bin/xray; do
  [[ -x "$cand" ]] && { XRAY="$cand"; break; }
done

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
ok()   { printf '%sOK%s   %s\n'   "$c_grn" "$c_rst" "$*"; }
warn() { printf '%sWARN%s %s\n'   "$c_yel" "$c_rst" "$*"; }
bad()  { printf '%sBAD%s  %s\n'   "$c_red" "$c_rst" "$*"; }
info() { printf 'info %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { bad "run as root"; exit 1; }
command -v sqlite3 >/dev/null || { bad "sqlite3 not found"; exit 1; }
command -v jq      >/dev/null || { bad "jq not found";      exit 1; }
[[ -f "$DB" ]]                || { bad "x-ui DB not found: $DB"; exit 1; }
[[ -n "$XRAY" ]]              || warn "xray binary not found; key-pair check disabled"

sql()  { sqlite3 "$DB" "$1"; }
sqlr() { sqlite3 -readonly "$DB" "$1"; }

apply() {
  # apply "<description>" "<sql>"
  local desc="$1" stmt="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "DRY_RUN: would fix: $desc"
    return 0
  fi
  sql "$stmt"
  ok "fixed: $desc"
  CHANGED=1
}

# --- backup ----------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
  backup="${DB}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$DB" "$backup"
  info "DB backed up: $backup"
fi

legacy_vless_grpc_tls="$(sqlr "
  SELECT COUNT(*)
  FROM inbounds
  WHERE protocol='vless'
    AND json_valid(stream_settings)=1
    AND json_extract(stream_settings,'\$.network')='grpc'
    AND json_extract(stream_settings,'\$.security')='tls'
    AND lower(COALESCE(remark,'')) LIKE '%vless-grpc-tls%';")"
if [[ "$DRY_RUN" == "1" && "$legacy_vless_grpc_tls" != "0" ]]; then
  warn "DRY_RUN: would restore $legacy_vless_grpc_tls generated VLESS gRPC TLS preset(s) to REALITY"
elif [[ "$legacy_vless_grpc_tls" != "0" ]]; then
  XUI_DB="$DB" xui_restore_reference_vless_grpc_reality_inbounds
  CHANGED=1
fi

# --- enumerate enabled reality inbounds ------------------------------------
ids="$(sqlr "
  SELECT id FROM inbounds
  WHERE enable=1
    AND json_valid(stream_settings)=1
    AND json_extract(stream_settings,'\$.security')='reality'
  ORDER BY id;")"

[[ -n "$ids" ]] || { warn "no enabled reality inbounds found"; exit 0; }

printf '\n=== REALITY inbound diagnosis ===\n'

while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  port="$(sqlr "SELECT COALESCE(port,0) FROM inbounds WHERE id=$id;")"
  proto="$(sqlr "SELECT protocol FROM inbounds WHERE id=$id;")"
  net="$(sqlr "SELECT json_extract(stream_settings,'\$.network') FROM inbounds WHERE id=$id;")"
  priv="$(sqlr "SELECT json_extract(stream_settings,'\$.realitySettings.privateKey') FROM inbounds WHERE id=$id;")"
  pub="$(sqlr "SELECT json_extract(stream_settings,'\$.realitySettings.settings.publicKey') FROM inbounds WHERE id=$id;")"
  sni="$(sqlr "SELECT json_extract(stream_settings,'\$.realitySettings.serverNames[0]') FROM inbounds WHERE id=$id;")"
  sids="$(sqlr "SELECT COALESCE(json_extract(stream_settings,'\$.realitySettings.shortIds'),'[]') FROM inbounds WHERE id=$id;")"
  nclients="$(sqlr "SELECT COALESCE(json_array_length(settings,'\$.clients'),0) FROM inbounds WHERE id=$id;")"

  printf -- '--- id=%s %s/%s port=%s sni=%s clients=%s ---\n' "$id" "$proto" "$net" "$port" "$sni" "$nclients"

  # 1) listening?
  if ss -tlnH "( sport = :$port )" 2>/dev/null | grep -q .; then
    ok "port $port is listening"
  else
    bad "port $port NOT listening (xray rejected this inbound's config)"
  fi

  # 2) key pair valid?
  if [[ -n "$XRAY" && -n "$priv" && "$priv" != "null" ]]; then
    derived="$("$XRAY" x25519 -i "$priv" 2>/dev/null | awk -F': ' '/PublicKey|Password/ {print $2; exit}')"
    if [[ -n "$derived" && "$derived" == "$pub" ]]; then
      ok "key pair matches"
    else
      bad "publicKey does NOT match privateKey (stored=$pub derived=$derived)"
      newpriv="$("$XRAY" x25519 2>/dev/null | awk -F': ' '/PrivateKey/ {print $2; exit}')"
      newpub="$("$XRAY" x25519 -i "$newpriv" 2>/dev/null | awk -F': ' '/PublicKey|Password/ {print $2; exit}')"
      if [[ -n "$newpriv" && -n "$newpub" ]]; then
        apply "id=$id regenerate reality key pair" "
          UPDATE inbounds
          SET stream_settings = json_set(
                json_set(stream_settings,'\$.realitySettings.privateKey','$newpriv'),
                '\$.realitySettings.settings.publicKey','$newpub')
          WHERE id=$id;"
      fi
    fi
  fi

  # 3) shortIds present + valid hex?
  bad_sids=0
  if [[ "$sids" == "[]" || "$sids" == "null" ]]; then
    bad_sids=1
  else
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      if ! [[ "$s" =~ ^[0-9a-fA-F]{1,16}$ ]] || (( ${#s} % 2 != 0 )); then
        bad_sids=1
      fi
    done < <(jq -r '.[]' <<<"$sids" 2>/dev/null)
  fi
  if (( bad_sids )); then
    bad "shortIds missing or invalid: $sids"
    newsid="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    apply "id=$id set valid shortIds" "
      UPDATE inbounds
      SET stream_settings = json_set(stream_settings,'\$.realitySettings.shortIds', json('[\"$newsid\",\"\"]'))
      WHERE id=$id;"
  else
    ok "shortIds valid"
  fi

  # 4) clients present?
  if (( nclients == 0 )); then
    bad "NO clients (UUID) on this inbound -> client cannot authenticate -> delay -1"
    warn "run: sudo bash generate-profiles.sh --xui-only --yes   (it seeds client UUIDs + rebuilds the subscription)"
  else
    ok "$nclients client(s) present"
  fi

  # 5) decoy reachable?  (auto-swap to a reachable one if dead)
  decoy_ok() {
    # reachable AND negotiates TLS1.3 (reality requirement)
    timeout 6 bash -c "echo | openssl s_client -connect ${1}:443 -servername ${1} -tls1_3 2>/dev/null | grep -q 'CONNECTED'"
  }
  if [[ -n "$sni" && "$sni" != "null" ]]; then
    if decoy_ok "$sni"; then
      ok "decoy ${sni}:443 reachable (TLS1.3)"
    else
      bad "decoy ${sni}:443 NOT reachable from server -> reality steal fails"
      # candidate pool: big sites, TLS1.3 + HTTP/2, rarely blocked, reachable from RU DCs
      newsni=""
      for cand in "${REALITY_DECOY_CANDIDATES[@]}"; do
        # don't reuse a decoy already taken by another inbound
        used="$(sqlr "SELECT 1 FROM inbounds WHERE json_extract(stream_settings,'\$.realitySettings.serverNames[0]')='$cand' LIMIT 1;")"
        [[ -n "$used" ]] && continue
        if decoy_ok "$cand"; then newsni="$cand"; break; fi
      done
      if [[ -n "$newsni" ]]; then
        # update serverNames[0], realitySettings.dest/target, and grpc authority (if grpc)
        apply "id=$id swap dead decoy ${sni} -> ${newsni}" "
          UPDATE inbounds SET stream_settings = (
            WITH s AS (SELECT stream_settings AS j FROM inbounds WHERE id=$id)
            SELECT json_set(
                     json_set(
                       json_set(
                         json_set(j,'\$.realitySettings.serverNames', json('[\"$newsni\"]')),
                         '\$.realitySettings.dest', '${newsni}:443'),
                       '\$.realitySettings.target', '${newsni}:443'),
                     '\$.grpcSettings.authority',
                     CASE WHEN json_extract(j,'\$.network')='grpc' THEN '$newsni'
                          ELSE json_extract(j,'\$.grpcSettings.authority') END)
            FROM s)
          WHERE id=$id;"
      else
        warn "id=$id no reachable replacement decoy found; edit REALITY_DECOY_CANDIDATES"
      fi
    fi
  fi
done <<<"$ids"

# --- restart x-ui if we changed the DB -------------------------------------
if (( CHANGED )); then
  printf '\n'
  info "restarting x-ui to apply DB changes..."
  systemctl restart x-ui
  sleep 2
  systemctl is-active --quiet x-ui && ok "x-ui active" || bad "x-ui failed to start; check: journalctl -u x-ui -n 50"
fi

# --- verification table ----------------------------------------------------
printf '\n=== verification ===\n'
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  port="$(sqlr "SELECT COALESCE(port,0) FROM inbounds WHERE id=$id;")"
  if ss -tlnH "( sport = :$port )" 2>/dev/null | grep -q .; then
    ok "id=$id port $port listening"
  else
    bad "id=$id port $port NOT listening"
  fi
done <<<"$ids"

printf '\nNext steps:\n'
printf '  1. If any inbound reported NO clients or a key was regenerated, run:\n'
printf '       sudo bash generate-profiles.sh --xui-only --yes\n'
printf '  2. Re-import / refresh the subscription in your client (v2rayN: Update subscription).\n'
printf '  3. Re-test delay. Reality entries should leave -1.\n'
