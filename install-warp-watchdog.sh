#!/usr/bin/env bash
# Install a systemd timer that checks WARP local proxy health every minute
# and restarts warp-svc when the SOCKS endpoint becomes unresponsive while
# systemctl still reports it active (silent-hang failure mode).
#
# Files installed:
#   /usr/local/sbin/upm-warp-watchdog.sh
#   /etc/systemd/system/upm-warp-watchdog.service
#   /etc/systemd/system/upm-warp-watchdog.timer
#
# Removal: sudo bash install-warp-watchdog.sh --uninstall --yes

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/lib/common.sh" ]] && source "$SCRIPT_DIR/lib/common.sh"

WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
CHECK_INTERVAL="${WARP_WATCHDOG_INTERVAL:-60}"
ASSUME_YES=0
UNINSTALL=0

usage() {
  cat <<EOF
Usage:
  sudo bash install-warp-watchdog.sh [options] --yes

Options:
  --host HOST         WARP proxy host (default: $WARP_PROXY_HOST)
  --port PORT         WARP proxy port (default: $WARP_PROXY_PORT)
  --interval SEC      Check interval in seconds (default: $CHECK_INTERVAL)
  --uninstall         Remove watchdog
  --yes               Skip confirmation
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) WARP_PROXY_HOST="${2:-}"; shift 2 ;;
    --port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --interval) CHECK_INTERVAL="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes"
[[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be numeric"

WATCHDOG_BIN=/usr/local/sbin/upm-warp-watchdog.sh
WATCHDOG_SVC=/etc/systemd/system/upm-warp-watchdog.service
WATCHDOG_TIMER=/etc/systemd/system/upm-warp-watchdog.timer

if [[ "$UNINSTALL" == "1" ]]; then
  systemctl disable --now upm-warp-watchdog.timer 2>/dev/null || true
  rm -f "$WATCHDOG_BIN" "$WATCHDOG_SVC" "$WATCHDOG_TIMER"
  systemctl daemon-reload
  ok "Watchdog removed"
  exit 0
fi

command_exists systemctl || die "systemctl required"
command_exists warp-cli || warn "warp-cli not in PATH; watchdog will still try to restart warp-svc on failure"

info "Installing WARP watchdog: ${WARP_PROXY_HOST}:${WARP_PROXY_PORT} every ${CHECK_INTERVAL}s"

WATCHDOG_CONTENT="#!/usr/bin/env bash
set -Eeuo pipefail
HOST='${WARP_PROXY_HOST}'
PORT='${WARP_PROXY_PORT}'
STATE_FILE=/var/lib/upm-warp-watchdog.state
mkdir -p \"\$(dirname \"\$STATE_FILE\")\"

probe() {
  local trace=''
  trace=\"\$(curl -fsS --max-time 8 --socks5-hostname \"\${HOST}:\${PORT}\" \\
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)\"
  grep -Eqi '^warp=(on|plus)\$' <<<\"\$trace\"
}

if probe; then
  printf 'ok %s\n' \"\$(date -u +%FT%TZ)\" > \"\$STATE_FILE\"
  exit 0
fi

# First failure → record, give one cycle grace.
last_state=\"\$(awk '{print \$1}' \"\$STATE_FILE\" 2>/dev/null || printf 'unknown')\"
if [[ \"\$last_state\" == 'ok' ]]; then
  printf 'fail %s\n' \"\$(date -u +%FT%TZ)\" > \"\$STATE_FILE\"
  printf 'WARP probe failed; awaiting next cycle before restart\n' >&2
  exit 0
fi

# Two consecutive failures → restart warp-svc.
printf 'WARP probe failed twice; restarting warp-svc\n' >&2
systemctl restart warp-svc || true
sleep 5
if command -v warp-cli >/dev/null 2>&1; then
  warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
fi
printf 'restarted %s\n' \"\$(date -u +%FT%TZ)\" > \"\$STATE_FILE\"
"

install -m 0755 /dev/stdin "$WATCHDOG_BIN" <<<"$WATCHDOG_CONTENT"

SERVICE_UNIT="[Unit]
Description=unified-proxy-manager WARP health watchdog
After=warp-svc.service network-online.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_BIN
"
install -m 0644 /dev/stdin "$WATCHDOG_SVC" <<<"$SERVICE_UNIT"

TIMER_UNIT="[Unit]
Description=Run unified-proxy-manager WARP watchdog every ${CHECK_INTERVAL}s

[Timer]
OnBootSec=2min
OnUnitActiveSec=${CHECK_INTERVAL}s
AccuracySec=5s
Unit=upm-warp-watchdog.service

[Install]
WantedBy=timers.target
"
install -m 0644 /dev/stdin "$WATCHDOG_TIMER" <<<"$TIMER_UNIT"

systemctl daemon-reload
systemctl enable --now upm-warp-watchdog.timer
sleep 2
if systemctl is-active --quiet upm-warp-watchdog.timer; then
  ok "WARP watchdog timer active. Probe state at /var/lib/upm-warp-watchdog.state"
else
  warn "Watchdog timer did not start cleanly; check journalctl -u upm-warp-watchdog.timer"
fi
