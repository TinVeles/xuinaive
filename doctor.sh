#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

XUI_DOMAIN="${XUI_DOMAIN:-}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"
MODE="${MODE:-}"
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
NH_PANEL_PORT="${NH_PANEL_PORT:-}"
NH_BACKEND_LISTEN="${NH_BACKEND_LISTEN:-127.0.0.1:9445}"
NH_NAIVE_LOGIN="${NH_NAIVE_LOGIN:-}"
NH_NAIVE_PASSWORD="${NH_NAIVE_PASSWORD:-}"
NH_NAIVE_LINK="${NH_NAIVE_LINK:-}"
WARP_ENABLED="${WARP_ENABLED:-0}"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"

load_config_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value:1:${#value}-2}"; value="${value//\\\"/\"}"; value="${value//\\\\/\\}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
    esac
    case "$key" in
      MODE|XUI_DOMAIN|NAIVE_DOMAIN|REALITY_DEST|NH_PROXY_DOMAIN|PROXY_DOMAIN|NH_PANEL_DOMAIN|PANEL_DOMAIN|NH_PANEL_PORT|NH_BACKEND_LISTEN|NH_NAIVE_LOGIN|NH_NAIVE_PASSWORD|NH_NAIVE_LINK|WARP_ENABLED|WARP_PROXY_HOST|WARP_PROXY_PORT|WARP_OUTBOUND_TAG)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  load_config_env "$SCRIPT_DIR/config.env"
fi
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"

load_naive_from_caddyfile() {
  local caddyfile="${1:-/etc/caddy-nh/Caddyfile}"
  [[ -f "$caddyfile" ]] || return 0

  if [[ -z "${NH_PROXY_DOMAIN:-}" ]]; then
    NH_PROXY_DOMAIN="$(awk '
      /^[[:space:]]*https:\/\// {
        gsub(/^https:\/\//,"",$1); split($1,a,":"); print a[1]; exit
      }
      /^[[:space:]]*:[0-9]+,/ {
        host=$2; gsub(/[,{]/,"",host); split(host,a,":"); print a[1]; exit
      }
    ' "$caddyfile" 2>/dev/null || true)"
  fi
  if [[ -z "${NH_NAIVE_LOGIN:-}" ]]; then
    NH_NAIVE_LOGIN="$(awk '/basic_auth/{print $2; exit}' "$caddyfile" 2>/dev/null || true)"
  fi
  if [[ -z "${NH_NAIVE_PASSWORD:-}" ]]; then
    NH_NAIVE_PASSWORD="$(awk '/basic_auth/{print $3; exit}' "$caddyfile" 2>/dev/null || true)"
  fi
}

load_naive_from_caddyfile "/etc/caddy-nh/Caddyfile"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

ok() { printf '%s\n' "${GREEN}OK:${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${NC} $*"; }
bad() { printf '%s\n' "${RED}BAD:${NC} $*"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

public_ipv4() {
  local ip=""
  if command_exists ip; then
    ip="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$ip" ]] && command_exists curl; then
    ip="$(curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  printf '%s\n' "$ip"
}

domain_a_records() {
  local domain="$1"
  if command_exists getent; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  elif command_exists dig; then
    dig +short A "$domain" 2>/dev/null | sort -u
  fi
}

port_details() {
  upm_port_details "$1"
}

xui_inbound_check() {
  local db="/etc/x-ui/x-ui.db"
  local rows id remark protocol port network security external_port expected_external_port socket_type details
  [[ -f "$db" ]] || { warn "x-ui database not found: $db"; return 0; }
  command_exists sqlite3 || { warn "sqlite3 missing; cannot inspect x-ui inbounds"; return 0; }

  rows="$(sqlite3 -separator $'\t' -readonly "$db" "
    SELECT id,
           COALESCE(remark,''),
           protocol,
           COALESCE(port,0),
           COALESCE(json_extract(stream_settings,'$.network'),''),
           COALESCE(json_extract(stream_settings,'$.security'),''),
           COALESCE(json_extract(stream_settings,'$.externalProxy[0].port'),'')
    FROM inbounds
    WHERE enable=1
    ORDER BY id;
  " 2>/dev/null || true)"
  [[ -n "$rows" ]] || { warn "No enabled x-ui inbounds found"; return 0; }

  while IFS=$'\t' read -r id remark protocol port network security external_port; do
    [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 ]] || continue
    socket_type="tcp"
    [[ "$protocol" == "hysteria" || "$protocol" == "hysteria2" ]] && socket_type="udp"
    details="$(port_details "$port")"
    if [[ -n "$details" ]]; then
      ok "x-ui inbound id=$id protocol=$protocol network=${network:-none} security=${security:-none} listens on ${port}/${socket_type}"
    else
      bad "x-ui inbound id=$id protocol=$protocol network=${network:-none} security=${security:-none} is enabled but ${port}/${socket_type} is not listening"
    fi
    expected_external_port="$port"
    if [[ "$security" == "reality" || "$network" == "ws" ]]; then
      expected_external_port="443"
    fi
    if [[ -n "$external_port" && "$external_port" != "$expected_external_port" ]]; then
      warn "x-ui inbound id=$id remark=$remark exports stale public port $external_port; expected $expected_external_port"
    fi
  done <<<"$rows"
}

xui_runtime_config_report() {
  local config="/usr/local/x-ui/bin/config.json"
  [[ -r "$config" ]] || { warn "x-ui runtime config not found: $config"; return 0; }
  command_exists jq || { warn "jq missing; cannot inspect x-ui runtime config"; return 0; }

  jq -r '
    .inbounds[]?
    | [
        (.tag // ""),
        (.listen // ""),
        ((.port // "") | tostring),
        (.protocol // ""),
        (.streamSettings.network // ""),
        (.streamSettings.security // "")
      ]
    | @tsv
  ' "$config" 2>/dev/null || warn "Cannot parse x-ui runtime config: $config"
}

xui_recent_log_report() {
  local output=""
  command_exists journalctl || { warn "journalctl missing; cannot inspect x-ui logs"; return 0; }
  output="$(journalctl -u x-ui -n 240 --no-pager -l 2>/dev/null \
    | grep -Ei 'XRAY:|xray|error|failed|warning|panic|fatal' \
    | tail -n 100 || true)"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    ok "No recent x-ui/Xray warnings or errors found"
  fi
}

service_active() {
  local svc="$1"
  command_exists systemctl && systemctl is-active --quiet "$svc" 2>/dev/null
}

tls_check() {
  local target="$1"
  local server_name="$2"
  local label="$3"
  local output=""

  if ! command_exists openssl; then
    warn "openssl missing; cannot check $label TLS"
    return 0
  fi

  output="$(timeout 12 openssl s_client \
    -connect "$target" \
    -servername "$server_name" \
    -alpn http/1.1 \
    -brief </dev/null 2>&1 || true)"

  if grep -Eq 'Protocol version: TLSv1\.[23]' <<<"$output" && grep -q 'Verification: OK' <<<"$output"; then
    ok "$label TLS works for $server_name at $target"
  else
    bad "$label TLS failed for $server_name at $target"
    printf '%s\n' "$output"
  fi
}

http_check() {
  local url="$1"
  local label="$2"
  local output=""

  if ! command_exists curl; then
    warn "curl missing; cannot check $label HTTP"
    return 0
  fi

  if output="$(curl -fsS --connect-timeout 5 --max-time 10 "$url" 2>&1 >/dev/null)"; then
    ok "$label responds at $url"
    return 0
  fi

  bad "$label does not respond at $url"
  [[ -n "$output" ]] && printf '%s\n' "$output"
}

naive_proxy_check() {
  local domain="${NH_PROXY_DOMAIN:-}"
  local user="${NH_NAIVE_LOGIN:-}"
  local pass="${NH_NAIVE_PASSWORD:-}"
  local auth=""
  local output=""

  [[ -n "$domain" ]] || return 0

  if [[ -z "$user" || -z "$pass" ]]; then
    warn "NaiveProxy credentials are missing in config.env; cannot run end-to-end proxy check"
    [[ -n "${NH_NAIVE_LINK:-}" ]] && echo "Saved Naive link: ${NH_NAIVE_LINK}"
    return 0
  fi

  if ! command_exists curl; then
    warn "curl missing; cannot run NaiveProxy end-to-end check"
    return 0
  fi

  if ! command_exists openssl; then
    warn "openssl missing; cannot run NaiveProxy CONNECT check"
    return 0
  fi

  auth="$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')"
  output="$(printf 'CONNECT www.cloudflare.com:443 HTTP/1.1\r\nHost: www.cloudflare.com:443\r\nProxy-Authorization: Basic %s\r\nProxy-Connection: Keep-Alive\r\n\r\n' "$auth" \
    | timeout 15 openssl s_client -connect "${domain}:443" -servername "$domain" -alpn http/1.1 -quiet 2>&1 \
    | head -n 20 || true)"

  if grep -q '^HTTP/1\.1 200' <<<"$output"; then
    ok "NaiveProxy CONNECT check works through https://${domain}:443"
  else
    bad "NaiveProxy CONNECT check failed through https://${domain}:443"
    printf '%s\n' "$output"
    echo "Check these next:"
    echo "- sudo nginx -T | grep -E '${domain}|nh_naive|proxy_protocol|9445'"
    echo "- sudo journalctl -u caddy-nh -n 80 --no-pager -l"
    echo "- sudo /usr/bin/caddy-nh validate --config /etc/caddy-nh/Caddyfile"
  fi
}

warp_check() {
  if ! command_exists warp-cli; then
    [[ "${WARP_ENABLED:-0}" == "1" ]] && bad "WARP is enabled in config.env but warp-cli is not installed"
    return 0
  fi

  local status_text=""
  status_text="$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true)"
  if grep -qi "connected" <<<"$status_text"; then
    ok "WARP status is connected"
  else
    warn "WARP status is not clearly connected"
    [[ -n "$status_text" ]] && printf '%s\n' "$status_text"
  fi

  if command_exists curl; then
    local trace=""
    trace="$(curl -fsS --max-time 20 --socks5-hostname "${WARP_PROXY_HOST}:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if grep -Eqi '^warp=(on|plus)' <<<"$trace"; then
      ok "WARP local proxy works at ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}"
    elif [[ -n "$trace" ]]; then
      warn "WARP local proxy responded, but trace did not report warp=on"
      printf '%s\n' "$trace" | grep -E '^(ip|loc|warp)=' || true
    else
      warn "WARP local proxy did not respond at ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}"
    fi
  fi
}

echo "Unified Proxy Manager doctor"
echo "============================"
echo

[[ "${EUID:-$(id -u)}" -eq 0 ]] && ok "Running as root" || warn "Not running as root; some listener process details may be incomplete"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12) ok "Supported OS: ${PRETTY_NAME:-$ID $VERSION_ID}" ;;
    *) warn "Untested OS: ${PRETTY_NAME:-unknown}" ;;
  esac
else
  warn "Cannot read /etc/os-release"
fi

echo
echo "Required commands:"
for cmd in curl wget git systemctl sqlite3 jq node; do
  command_exists "$cmd" && ok "$cmd found" || bad "$cmd missing"
done

echo
echo "DNS:"
server_ip="$(public_ipv4)"
[[ -n "$server_ip" ]] && ok "Detected public IPv4: $server_ip" || warn "Could not detect public IPv4"
for domain in "${XUI_DOMAIN:-}" "${NAIVE_DOMAIN:-}" "${REALITY_DEST:-}" "${NH_PROXY_DOMAIN:-}" "${NH_PANEL_DOMAIN:-}"; do
  [[ -n "$domain" ]] || continue
  records="$(domain_a_records "$domain" | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  if [[ -z "$records" ]]; then
    bad "$domain has no detected A record"
  elif [[ -n "$server_ip" ]] && grep -qw "$server_ip" <<<"$records"; then
    ok "$domain resolves to this server"
  else
    warn "$domain resolves to [$records], expected $server_ip"
  fi
done

echo
echo "Ports:"
for port in 80 443 2053 3000 8080 8081 8443 9443 9445 "$WARP_PROXY_PORT"; do
  details="$(port_details "$port")"
  if [[ -n "$details" ]]; then
    warn "Port $port is busy:"
    printf '%s\n' "$details"
  else
    ok "Port $port is free or not detected"
  fi
done

echo
echo "x-ui enabled inbounds:"
xui_inbound_check

echo
echo "x-ui runtime inbounds:"
xui_runtime_config_report

echo
echo "x-ui recent warnings/errors:"
xui_recent_log_report

echo
echo "Services:"
if command_exists systemctl; then
  for svc in x-ui nginx caddy caddy-nh hysteria-server panel-naive-hy2 warp-svc ufw; do
    printf '%-8s active=%-10s enabled=%s\n' \
      "$svc" \
      "$(systemctl is-active "$svc" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  done
else
  warn "systemctl not available"
fi

if command_exists warp-cli || [[ "${WARP_ENABLED:-0}" == "1" ]]; then
  echo
  echo "WARP:"
  warp_check
fi

echo
echo "Conflict analysis:"
if service_active nginx && service_active caddy; then
  warn "nginx and public caddy are both active. On one VPS, only one service should own public 443 unless a single SNI router is configured."
elif service_active nginx && service_active caddy-nh && service_active hysteria-server; then
  ok "nginx, caddy-nh, and hysteria-server are active. This is expected for all-in-one mode."
elif service_active caddy && service_active hysteria-server; then
  ok "caddy and hysteria-server are both active. This is expected for NHM mode when Caddy owns TCP/443 and Hy2 owns UDP/443."
else
  ok "No obvious nginx+caddy dual-active conflict"
fi

if [[ -n "${NH_PROXY_DOMAIN:-}" ]]; then
  echo
  echo "NHM/Naive TLS:"
  tls_check "${NH_BACKEND_LISTEN:-127.0.0.1:9445}" "$NH_PROXY_DOMAIN" "Caddy backend"
  tls_check "${NH_PROXY_DOMAIN}:443" "$NH_PROXY_DOMAIN" "Public nginx stream"

  echo
  echo "NaiveProxy end-to-end:"
  naive_proxy_check
fi

if service_active panel-naive-hy2 || [[ -n "${NH_PANEL_PORT:-}" || -n "${NH_PANEL_DOMAIN:-}" ]]; then
  echo
  echo "NHM Panel HTTP:"
  http_check "http://127.0.0.1:3000/" "Panel backend"
  if [[ -n "${NH_PANEL_PORT:-}" ]]; then
    http_check "http://127.0.0.1:${NH_PANEL_PORT}/" "Panel nginx proxy"
    if [[ -n "${server_ip:-}" ]]; then
      http_check "http://${server_ip}:${NH_PANEL_PORT}/" "Panel public IP"
    else
      warn "Public IPv4 is unknown; cannot check panel public URL"
    fi
  fi
fi

echo
echo "Network leak detection:"

if command_exists resolvectl; then
  resolv_output="$(resolvectl status 2>/dev/null || true)"
  if grep -qE '\+DNSOverTLS|DNS over TLS:.*yes|DNSOverTLS=opportunistic|DNSOverTLS=yes' <<<"$resolv_output"; then
    ok "System DNS uses DoT (DNS-over-TLS)"
  else
    warn "System DNS is NOT using DoT. DNS queries leak in plaintext to upstream resolver. Run: bash network-hardening.sh --apply --yes"
  fi
  current_dns="$(awk '/Current DNS Server/{print $NF; exit}' <<<"$resolv_output" 2>/dev/null)"
  [[ -n "$current_dns" ]] && info "Current resolver: $current_dns"
else
  warn "resolvectl not available; cannot verify DNS leak status"
fi

if ip -6 addr show 2>/dev/null | grep -q 'scope global'; then
  global_v6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}')"
  if [[ -f /etc/sysctl.d/99-upm-ipv6.conf ]] && grep -q 'disable_ipv6 = 1' /etc/sysctl.d/99-upm-ipv6.conf; then
    ok "IPv6 globally disabled by network-hardening.sh"
  else
    info "Public IPv6 present: $global_v6"
    if command_exists ss; then
      v6_listeners="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -cE '^\[::\]:|^\[fe80|^\[2|^\[3' || printf '0')"
      if [[ "$v6_listeners" -gt 0 ]]; then
        ok "$v6_listeners IPv6 listeners present"
      else
        warn "Public IPv6 exists but no IPv6 listeners on this host. Clients with IPv6 connectivity may bypass your proxy stack. Disable IPv6 or bind listeners on it."
      fi
    fi
  fi
else
  ok "No public IPv6 (no leak vector)"
fi

if command_exists sysctl; then
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  ka="$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo unknown)"
  [[ "$cc" == "bbr" ]] && ok "TCP congestion: bbr" || warn "TCP congestion: $cc (expected bbr)"
  [[ "$qdisc" == "fq" || "$qdisc" == "fq_codel" ]] && ok "Qdisc: $qdisc" || warn "Qdisc: $qdisc (expected fq)"
  if [[ "$ka" != "unknown" && "$ka" -le 300 ]]; then
    ok "TCP keepalive: ${ka}s (suitable for long-lived proxy sessions)"
  else
    warn "TCP keepalive: ${ka}s. Run network-hardening.sh to apply 120s default."
  fi
fi

if [[ "${WARP_ENABLED:-0}" == "1" ]] || command_exists warp-cli; then
  snippet=/etc/x-ui/warp-generated-routing.json
  if [[ -f "$snippet" ]]; then
    if grep -q '"https://1.1.1.1/dns-query"' "$snippet" 2>/dev/null; then
      ok "Xray WARP snippet routes AI-domain DNS through DoH (no plaintext DNS leak)"
    else
      warn "Xray WARP snippet missing DoH DNS section; regenerate via generate-profiles.sh"
    fi
  fi
fi

echo
echo "Recommendations:"
echo "- Run install.sh first in dry-run mode only."
echo "- Make sure DNS A records point to this VPS before any TLS issuance."
echo "- In --mode all, keep DNS and public 80/tcp reachable; the installer handles nginx webroot ACME and standalone fallback automatically."
echo "- If WARP is enabled, use outbound tag ${WARP_OUTBOUND_TAG:-warp-cli} and local proxy ${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000} in 3x-ui/Xray routing."
echo "- Do not run x-ui-pro.sh directly on a server with existing nginx/x-ui data without backups."
echo "- Use --mode nh only as a standalone NHM Panel deployment unless you have reviewed public 443 ownership."
