#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

XUI_DOMAIN="${XUI_DOMAIN:-}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"
RIXXX_DOMAIN="${RIXXX_DOMAIN:-}"
RIXXX_EMAIL="${RIXXX_EMAIL:-}"
RIXXX_BACKEND_LISTEN="${RIXXX_BACKEND_LISTEN:-}"
RIXXX_ACCESS="${RIXXX_ACCESS:-}"
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
NH_EMAIL="${NH_EMAIL:-${NH_PROXY_EMAIL:-}}"
NH_PANEL_PORT="${NH_PANEL_PORT:-8081}"
NH_BACKEND_LISTEN="${NH_BACKEND_LISTEN:-127.0.0.1:9445}"
NH_TLS_CERT="${NH_TLS_CERT:-}"
NH_TLS_KEY="${NH_TLS_KEY:-}"
WARP_ENABLED="${WARP_ENABLED:-0}"
WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_SNIPPET_FILE="${WARP_SNIPPET_FILE:-/etc/x-ui/warp-xray-snippets.json}"

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
      XUI_DOMAIN|NAIVE_DOMAIN|REALITY_DEST|RIXXX_DOMAIN|RIXXX_EMAIL|RIXXX_BACKEND_LISTEN|RIXXX_ACCESS|NH_PROXY_DOMAIN|PROXY_DOMAIN|NH_PANEL_DOMAIN|PANEL_DOMAIN|NH_EMAIL|NH_PROXY_EMAIL|NH_PANEL_PORT|NH_BACKEND_LISTEN|NH_TLS_CERT|NH_TLS_KEY|WARP_ENABLED|WARP_PROXY_HOST|WARP_PROXY_PORT|WARP_OUTBOUND_TAG|WARP_SNIPPET_FILE)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  load_config_env "$SCRIPT_DIR/config.env"
fi
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PROXY_DOMAIN="${RIXXX_DOMAIN:-$NH_PROXY_DOMAIN}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
NH_EMAIL="${NH_EMAIL:-${NH_PROXY_EMAIL:-}}"
NH_EMAIL="${RIXXX_EMAIL:-$NH_EMAIL}"
NH_BACKEND_LISTEN="${RIXXX_BACKEND_LISTEN:-$NH_BACKEND_LISTEN}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

service_line() {
  local svc="$1"
  if ! command_exists systemctl; then
    printf '%-8s systemctl not available\n' "$svc"
    return 0
  fi
  printf '%-8s active=%-10s enabled=%s\n' \
    "$svc" \
    "$(systemctl is-active "$svc" 2>/dev/null || true)" \
    "$(systemctl is-enabled "$svc" 2>/dev/null || true)"
}

port_details() {
  upm_port_details "$1"
}

echo "Unified Proxy Manager status"
echo "============================"
echo
echo "Configured domains:"
echo "  XUI_DOMAIN=${XUI_DOMAIN:-not set}"
echo "  NAIVE_DOMAIN=${NAIVE_DOMAIN:-not set}"
echo "  REALITY_DEST=${REALITY_DEST:-not set}"
echo "  RIXXX_DOMAIN=${NH_PROXY_DOMAIN:-not set}"
echo "  RIXXX_EMAIL=${NH_EMAIL:-not set}"
echo "  RIXXX_BACKEND_LISTEN=${NH_BACKEND_LISTEN:-not set}"
echo "  RIXXX_PANEL=127.0.0.1:3000"
echo "  WARP_ENABLED=${WARP_ENABLED:-not set}"
echo "  WARP_PROXY=${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000}"
echo "  WARP_OUTBOUND_TAG=${WARP_OUTBOUND_TAG:-warp-cli}"
echo "  WARP_SNIPPET_FILE=${WARP_SNIPPET_FILE:-not set}"
if [[ -f "$SCRIPT_DIR/access-info.txt" ]]; then
  echo "  ACCESS_INFO=$SCRIPT_DIR/access-info.txt"
fi

echo
echo "Services:"
service_line x-ui
service_line nginx
service_line caddy
service_line caddy-naive
service_line mita
service_line warp-svc
service_line ufw
if command_exists pm2; then
  echo
  echo "PM2:"
  pm2 status panel-naive-mieru 2>/dev/null || pm2 status 2>/dev/null || true
fi

echo
echo "Listening ports:"
for port in 80 443 2053 3000 7443 8080 8081 8443 9443 9445 "$WARP_PROXY_PORT"; do
  details="$(port_details "$port")"
  if [[ -n "$details" ]]; then
    printf 'port %s: busy\n%s\n' "$port" "$details"
  else
    printf 'port %s: free or not detected\n' "$port"
  fi
done

echo
echo "WARP:"
if command_exists warp-cli; then
  warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true
else
  echo "warp-cli not installed"
fi

echo
echo "Recent logs:"
if command_exists journalctl && command_exists systemctl; then
  for svc in x-ui nginx caddy caddy-naive mita warp-svc; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      printf '\n-- %s last 30 lines --\n' "$svc"
      journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true
    fi
  done
else
  echo "journalctl/systemctl not available"
fi
