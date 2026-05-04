#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

XUI_DOMAIN="${XUI_DOMAIN:-}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
NH_PANEL_PORT="${NH_PANEL_PORT:-8081}"
NH_BACKEND_LISTEN="${NH_BACKEND_LISTEN:-127.0.0.1:9445}"
NH_NAIVE_LOGIN="${NH_NAIVE_LOGIN:-}"
NH_NAIVE_PASSWORD="${NH_NAIVE_PASSWORD:-}"
NH_NAIVE_LINK="${NH_NAIVE_LINK:-}"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/config.env"
fi

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
  local port="$1"
  if command_exists ss; then
    ss -H -ltnup "sport = :$port" 2>/dev/null || true
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  else
    return 0
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

  output="$(curl -fsS \
    --connect-timeout 10 \
    --max-time 25 \
    -x "https://${user}:${pass}@${domain}:443" \
    https://www.cloudflare.com/cdn-cgi/trace 2>&1 || true)"

  if grep -q '^colo=' <<<"$output" && grep -q '^tls=' <<<"$output"; then
    ok "NaiveProxy end-to-end check works through https://${domain}:443"
  else
    bad "NaiveProxy end-to-end check failed through https://${domain}:443"
    printf '%s\n' "$output"
    echo "Check these next:"
    echo "- sudo nginx -T | grep -E '${domain}|nh_naive|proxy_protocol|9445'"
    echo "- sudo journalctl -u caddy-nh -n 80 --no-pager -l"
    echo "- sudo /usr/bin/caddy-nh validate --config /etc/caddy-nh/Caddyfile"
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
for cmd in curl wget git systemctl; do
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
for port in 80 443 2053 3000 8080 8081 8443 9443 9445; do
  details="$(port_details "$port")"
  if [[ -n "$details" ]]; then
    warn "Port $port is busy:"
    printf '%s\n' "$details"
  else
    ok "Port $port is free or not detected"
  fi
done

echo
echo "Services:"
if command_exists systemctl; then
  for svc in x-ui nginx caddy caddy-nh hysteria-server panel-naive-hy2 ufw; do
    printf '%-8s active=%-10s enabled=%s\n' \
      "$svc" \
      "$(systemctl is-active "$svc" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  done
else
  warn "systemctl not available"
fi

echo
echo "Conflict analysis:"
if service_active nginx && service_active caddy; then
  warn "nginx and public caddy are both active. On one VPS, only one service should own public 443 unless a single SNI router is configured."
elif service_active nginx && service_active caddy-nh && service_active hysteria-server; then
  ok "nginx, caddy-nh, and hysteria-server are active. This is expected for all-in-one mode."
elif service_active caddy && service_active hysteria-server; then
  ok "caddy and hysteria-server are both active. This is expected for N+H mode when Caddy owns TCP/443 and Hy2 owns UDP/443."
else
  ok "No obvious nginx+caddy dual-active conflict"
fi

if [[ -n "${NH_PROXY_DOMAIN:-}" ]]; then
  echo
  echo "N+H/Naive TLS:"
  tls_check "${NH_BACKEND_LISTEN:-127.0.0.1:9445}" "$NH_PROXY_DOMAIN" "Caddy backend"
  tls_check "${NH_PROXY_DOMAIN}:443" "$NH_PROXY_DOMAIN" "Public nginx stream"

  echo
  echo "NaiveProxy end-to-end:"
  naive_proxy_check
fi

if service_active panel-naive-hy2 || [[ -n "${NH_PANEL_PORT:-}" ]]; then
  echo
  echo "N+H Panel HTTP:"
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
echo "Recommendations:"
echo "- Run install.sh first in dry-run mode only."
echo "- Make sure DNS A records point to this VPS before any TLS issuance."
echo "- In --mode all, keep DNS and public 80/tcp reachable; the installer handles nginx webroot ACME and standalone fallback automatically."
echo "- Do not run x-ui-pro.sh directly on a server with existing nginx/x-ui data without backups."
echo "- Use --mode nh only as a standalone N+H panel deployment unless you have reviewed public 443 ownership."
