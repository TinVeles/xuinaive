#!/usr/bin/env bash
# Apply systemd drop-in overrides to all unified-proxy-manager services for
# auto-recovery, file-descriptor headroom, and OOM resistance.
#
# Default: dry-run. Add --apply --yes to make changes.
#
# Drop-ins are written to /etc/systemd/system/<service>.service.d/upm-stability.conf
# so upstream unit-file updates are preserved.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/lib/common.sh" ]] && source "$SCRIPT_DIR/lib/common.sh"

APPLY=0
ASSUME_YES=0
SERVICES_DEFAULT=(x-ui nginx caddy-nh hysteria-server panel-naive-hy2 warp-svc)
SERVICES=()

usage() {
  cat <<EOF
Usage:
  sudo bash service-stability.sh [options]

Default: dry-run. Pass --apply --yes to write drop-ins and reload services.

Options:
  --apply              Write drop-ins and reload affected services
  --yes                Skip interactive confirmation
  --service NAME       Restrict to one service (repeatable)
  --remove             Remove unified-proxy-manager drop-ins instead of installing
  -h, --help           Show help

Default services: ${SERVICES_DEFAULT[*]}

What it sets per service:
  Restart=on-failure
  RestartSec=10s
  StartLimitIntervalSec=300s
  StartLimitBurst=10
  LimitNOFILE=1048576
  LimitNPROC=65536
  TasksMax=infinity
  OOMScoreAdjust=-500
  TimeoutStopSec=15s
EOF
}

REMOVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --service) SERVICES+=("${2:-}"); shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "${#SERVICES[@]}" -eq 0 ]] && SERVICES=("${SERVICES_DEFAULT[@]}")

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf '[dry-run] %s\n' "$*"
  fi
}

write_dropin() {
  local svc="$1"
  local dir="/etc/systemd/system/${svc}.service.d"
  local file="$dir/upm-stability.conf"
  if [[ "$REMOVE" -eq 1 ]]; then
    if [[ -f "$file" ]]; then
      run rm -f "$file"
      run rmdir --ignore-fail-on-non-empty "$dir" 2>/dev/null || true
      info "Removed drop-in for $svc"
    else
      info "$svc: no drop-in to remove"
    fi
    return 0
  fi
  local content="# unified-proxy-manager service stability hardening.
# Applied by service-stability.sh.
[Unit]
StartLimitIntervalSec=300s
StartLimitBurst=10

[Service]
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
LimitNPROC=65536
TasksMax=infinity
OOMScoreAdjust=-500
TimeoutStopSec=15s
"
  if [[ "$APPLY" -eq 1 ]]; then
    install -d -m 0755 "$dir"
    local tmp; tmp="$(mktemp)"
    printf '%s' "$content" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    printf '+ wrote %s\n' "$file"
  else
    printf '[dry-run] write %s\n' "$file"
  fi
}

if [[ "$APPLY" -eq 1 && "$ASSUME_YES" -ne 1 ]]; then
  warn "Will modify systemd drop-ins for: ${SERVICES[*]}"
  read -r -p "Type APPLY to continue: " answer
  [[ "$answer" == "APPLY" ]] || die "Cancelled"
fi

backup_dir="/opt/unified-proxy-manager/backups/service-stability-$(date '+%Y-%m-%d-%H-%M-%S')"
if [[ "$APPLY" -eq 1 ]]; then
  install -d -m 0700 "$backup_dir"
fi

affected=()
for svc in "${SERVICES[@]}"; do
  if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    info "${svc}.service not present; skipping"
    continue
  fi
  if [[ "$APPLY" -eq 1 && -f "/etc/systemd/system/${svc}.service.d/upm-stability.conf" ]]; then
    cp -a "/etc/systemd/system/${svc}.service.d/upm-stability.conf" "$backup_dir/${svc}.upm-stability.conf.bak" 2>/dev/null || true
  fi
  write_dropin "$svc"
  affected+=("$svc")
done

if [[ "${#affected[@]}" -eq 0 ]]; then
  warn "No matching services found on this system"
  exit 0
fi

run systemctl daemon-reload
for svc in "${affected[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    run systemctl restart "$svc" || warn "$svc: restart returned non-zero"
  fi
done

if [[ "$APPLY" -eq 1 ]]; then
  for svc in "${affected[@]}"; do
    sleep 1
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      nofile="$(systemctl show -p LimitNOFILESoft --value "$svc" 2>/dev/null || printf '?')"
      restart="$(systemctl show -p Restart --value "$svc" 2>/dev/null || printf '?')"
      ok "$svc: active, Restart=$restart, LimitNOFILE=$nofile"
    else
      warn "$svc: not active after restart; check journalctl -u $svc"
    fi
  done
fi

ok "Service stability pass complete (mode: $([[ "$APPLY" -eq 1 ]] && printf 'apply' || printf 'dry-run'))"
[[ "$APPLY" -eq 1 ]] || info "Rerun with --apply --yes to apply"
