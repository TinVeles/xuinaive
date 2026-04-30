#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

XUI_DOMAIN="${XUI_DOMAIN:-}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/config.env"
fi

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
  local port="$1"
  if command_exists ss; then
    ss -H -ltnup "sport = :$port" 2>/dev/null || true
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  else
    return 0
  fi
}

echo "Unified Proxy Manager status"
echo "============================"
echo
echo "Configured domains:"
echo "  XUI_DOMAIN=${XUI_DOMAIN:-not set}"
echo "  NAIVE_DOMAIN=${NAIVE_DOMAIN:-not set}"
echo "  REALITY_DEST=${REALITY_DEST:-not set}"

echo
echo "Services:"
service_line x-ui
service_line nginx
service_line caddy
service_line caddy-naive
service_line ufw

echo
echo "Listening ports:"
for port in 80 443 2053 7443 8080 8443 9443 9444; do
  details="$(port_details "$port")"
  if [[ -n "$details" ]]; then
    printf 'port %s: busy\n%s\n' "$port" "$details"
  else
    printf 'port %s: free or not detected\n' "$port"
  fi
done

echo
echo "Recent logs:"
if command_exists journalctl && command_exists systemctl; then
  for svc in x-ui nginx caddy caddy-naive; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      printf '\n-- %s last 30 lines --\n' "$svc"
      journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true
    fi
  done
else
  echo "journalctl/systemctl not available"
fi
