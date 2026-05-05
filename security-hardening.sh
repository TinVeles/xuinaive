#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
ASSUME_YES=0
SSH_PORT="22"
PANEL_PORT="8081"
PANEL_MODE="ssh-only"
ALLOW_PANEL_FROM=""
INSTALL_FAIL2BAN=1
INSTALL_UPDATES=1
ENABLE_PROBE_RESISTANCE=1
SSH_DISABLE_PASSWORD=0
SSH_DISABLE_ROOT=0
EXTRA_ALLOW_RULES=()

usage() {
  cat <<'EOF'
Usage:
  sudo bash security-hardening.sh [options]

Default mode is dry-run. Add --apply --yes to make changes.

Common safe profile:
  sudo bash security-hardening.sh --apply --yes

Options:
  --apply                     Apply changes. Without this, only prints actions.
  --yes                       Do not ask for confirmation.
  --ssh-port PORT             SSH port to keep open in UFW. Default: 22.
  --panel-port PORT           N+H panel public nginx port. Default: 8081.
  --panel-mode ssh-only       Close panel port publicly. Default.
  --panel-mode public         Keep panel port publicly open.
  --panel-mode allow-ip       Allow panel only from --allow-panel-from.
  --allow-panel-from CIDR     IP/CIDR allowed to access panel, for allow-ip mode.
  --no-fail2ban               Do not install/configure fail2ban.
  --no-auto-updates           Do not install/configure unattended-upgrades.
  --no-probe-resistance       Do not add probe_resistance to /etc/caddy-nh/Caddyfile.
  --ssh-disable-password      Disable SSH password login.
  --ssh-disable-root          Disable SSH root login. Risky unless a sudo user exists.
  --allow-port PORT[/PROTO]   Keep an extra port open, e.g. 8443/tcp. Repeatable.
  -h, --help                  Show this help.

Firewall profile:
  allow SSH_PORT/tcp
  allow 80/tcp
  allow 443/tcp
  allow 443/udp
  close or restrict PANEL_PORT/tcp depending on panel mode
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf '[dry-run] %s\n' "$*"
  fi
}

run_shell() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '+ %s\n' "$*"
    bash -c "$*"
  else
    printf '[dry-run] %s\n' "$*"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

service_restart_ssh() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run systemctl restart ssh
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    run systemctl restart sshd
  else
    warn "SSH service unit not found; skipping SSH restart"
  fi
}

public_ipv4() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$ip" ]] && command_exists ip; then
    ip="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  printf '%s\n' "$ip"
}

port_details() {
  local port="$1"
  if command_exists ss; then
    ss -H -ltnup "sport = :$port" 2>/dev/null || true
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --panel-port) PANEL_PORT="${2:-}"; shift 2 ;;
    --panel-mode) PANEL_MODE="${2:-}"; shift 2 ;;
    --allow-panel-from) ALLOW_PANEL_FROM="${2:-}"; shift 2 ;;
    --no-fail2ban) INSTALL_FAIL2BAN=0; shift ;;
    --no-auto-updates) INSTALL_UPDATES=0; shift ;;
    --no-probe-resistance) ENABLE_PROBE_RESISTANCE=0; shift ;;
    --ssh-disable-password) SSH_DISABLE_PASSWORD=1; shift ;;
    --ssh-disable-root) SSH_DISABLE_ROOT=1; shift ;;
    --allow-port) EXTRA_ALLOW_RULES+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "--ssh-port must be a port number"
[[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || die "--panel-port must be a port number"
case "$PANEL_MODE" in
  ssh-only|public|allow-ip) ;;
  *) die "--panel-mode must be ssh-only, public, or allow-ip" ;;
esac
if [[ "$PANEL_MODE" == "allow-ip" && -z "$ALLOW_PANEL_FROM" ]]; then
  die "--allow-panel-from is required with --panel-mode allow-ip"
fi

echo "Unified Proxy Manager security hardening"
echo "========================================"
echo
echo "Mode:             $([[ "$APPLY" -eq 1 ]] && echo apply || echo dry-run)"
echo "SSH port:         ${SSH_PORT}/tcp"
echo "Panel mode:       ${PANEL_MODE}"
echo "Panel port:       ${PANEL_PORT}/tcp"
[[ -n "$ALLOW_PANEL_FROM" ]] && echo "Panel allow from: ${ALLOW_PANEL_FROM}"
echo "fail2ban:         $([[ "$INSTALL_FAIL2BAN" -eq 1 ]] && echo yes || echo no)"
echo "auto updates:     $([[ "$INSTALL_UPDATES" -eq 1 ]] && echo yes || echo no)"
echo "probe resistance: $([[ "$ENABLE_PROBE_RESISTANCE" -eq 1 ]] && echo yes || echo no)"
echo "SSH passwords:    $([[ "$SSH_DISABLE_PASSWORD" -eq 1 ]] && echo disable || echo unchanged)"
echo "SSH root login:   $([[ "$SSH_DISABLE_ROOT" -eq 1 ]] && echo disable || echo unchanged)"
if [[ "${#EXTRA_ALLOW_RULES[@]}" -gt 0 ]]; then
  printf 'Extra allow:       %s\n' "${EXTRA_ALLOW_RULES[*]}"
fi
echo

server_ip="$(public_ipv4)"
[[ -n "$server_ip" ]] && ok "Detected public IPv4: $server_ip" || warn "Could not detect public IPv4"

if [[ "$APPLY" -eq 1 && "$ASSUME_YES" -ne 1 ]]; then
  warn "This can change firewall, SSH, Caddy, and package configuration."
  read -r -p "Type APPLY to continue: " answer
  [[ "$answer" == "APPLY" ]] || die "Cancelled"
fi

backup_dir="/opt/unified-proxy-manager/backups/security-$(date '+%Y-%m-%d-%H-%M-%S')"
if [[ "$APPLY" -eq 1 ]]; then
  mkdir -p "$backup_dir"
  for path in /etc/ufw /etc/fail2ban /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/caddy-nh/Caddyfile "$SCRIPT_DIR/config.env" "$SCRIPT_DIR/access-info.txt"; do
    if [[ -e "$path" || -L "$path" ]]; then
      mkdir -p "$backup_dir$(dirname "$path")"
      cp -a "$path" "$backup_dir$(dirname "$path")/" || true
    fi
  done
  ok "Backup directory: $backup_dir"
else
  info "Backup would be created under /opt/unified-proxy-manager/backups/security-*"
fi

if [[ "$INSTALL_FAIL2BAN" -eq 1 || "$INSTALL_UPDATES" -eq 1 ]]; then
  run apt-get update
  packages=()
  [[ "$INSTALL_FAIL2BAN" -eq 1 ]] && packages+=(fail2ban)
  [[ "$INSTALL_UPDATES" -eq 1 ]] && packages+=(unattended-upgrades apt-listchanges)
  run apt-get install -y "${packages[@]}"
fi

if [[ "$INSTALL_FAIL2BAN" -eq 1 ]]; then
  run mkdir -p /etc/fail2ban/jail.d
  run_shell "cat > /etc/fail2ban/jail.d/unified-proxy-manager.local <<'EOF'
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF"
  run systemctl enable fail2ban
  run systemctl restart fail2ban
fi

if [[ "$INSTALL_UPDATES" -eq 1 ]]; then
  run dpkg-reconfigure -f noninteractive unattended-upgrades
fi

if [[ "$SSH_DISABLE_PASSWORD" -eq 1 || "$SSH_DISABLE_ROOT" -eq 1 ]]; then
  if [[ "$SSH_DISABLE_PASSWORD" -eq 1 && ! -s /root/.ssh/authorized_keys ]]; then
    warn "Root authorized_keys is missing or empty. Make sure another key-based sudo user exists before applying."
  fi
  run mkdir -p /etc/ssh/sshd_config.d
  ssh_root_line="# PermitRootLogin unchanged"
  [[ "$SSH_DISABLE_ROOT" -eq 1 ]] && ssh_root_line="PermitRootLogin no"
  ssh_password_lines="# PasswordAuthentication unchanged"
  if [[ "$SSH_DISABLE_PASSWORD" -eq 1 ]]; then
    ssh_password_lines=$'PasswordAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no'
    [[ "$SSH_DISABLE_ROOT" -eq 0 ]] && ssh_root_line="PermitRootLogin prohibit-password"
  fi
  run_shell "cat > /etc/ssh/sshd_config.d/99-unified-hardening.conf <<'EOF'
${ssh_password_lines}
${ssh_root_line}
EOF"
  if [[ "$APPLY" -eq 1 ]]; then
    sshd -t || die "sshd config validation failed; backup is in $backup_dir"
  else
    printf '[dry-run] sshd -t\n'
  fi
  service_restart_ssh
fi

if [[ "$ENABLE_PROBE_RESISTANCE" -eq 1 ]]; then
  if [[ -f /etc/caddy-nh/Caddyfile ]]; then
    if grep -q 'probe_resistance' /etc/caddy-nh/Caddyfile; then
      ok "probe_resistance is already present in /etc/caddy-nh/Caddyfile"
    else
      run_shell "sed -i '/hide_via/a\\    probe_resistance' /etc/caddy-nh/Caddyfile"
      if [[ "$APPLY" -eq 1 ]]; then
        /usr/bin/caddy-nh validate --config /etc/caddy-nh/Caddyfile || die "Caddyfile validation failed after probe_resistance change"
      else
        printf '[dry-run] /usr/bin/caddy-nh validate --config /etc/caddy-nh/Caddyfile\n'
      fi
      run systemctl reload caddy-nh
    fi
  else
    warn "/etc/caddy-nh/Caddyfile not found; skipping probe_resistance"
  fi
fi

run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow "${SSH_PORT}/tcp"
run ufw allow 80/tcp
run ufw allow 443/tcp
run ufw allow 443/udp
for rule in "${EXTRA_ALLOW_RULES[@]}"; do
  [[ -n "$rule" ]] || continue
  run ufw allow "$rule"
done

case "$PANEL_MODE" in
  ssh-only)
    run ufw deny "${PANEL_PORT}/tcp"
    ;;
  public)
    run ufw allow "${PANEL_PORT}/tcp"
    ;;
  allow-ip)
    run ufw allow from "$ALLOW_PANEL_FROM" to any port "$PANEL_PORT" proto tcp
    run ufw deny "${PANEL_PORT}/tcp"
    ;;
esac

run ufw --force enable
run ufw reload

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  run chmod 600 "$SCRIPT_DIR/config.env"
fi
if [[ -f "$SCRIPT_DIR/access-info.txt" ]]; then
  run chmod 600 "$SCRIPT_DIR/access-info.txt"
fi

echo
echo "Post-hardening checks"
echo "---------------------"
for port in 80 443 9445 "$PANEL_PORT"; do
  details="$(port_details "$port")"
  if [[ -n "$details" ]]; then
    printf 'port %s listeners:\n%s\n' "$port" "$details"
  else
    printf 'port %s: no listener detected\n' "$port"
  fi
done

if [[ -f /etc/caddy-nh/Caddyfile ]]; then
  if grep -qE '^:9445, .*:9445 \{' /etc/caddy-nh/Caddyfile; then
    ok "N+H Caddyfile uses Naive-compatible :9445, domain:9445 site address"
  else
    warn "N+H Caddyfile site address does not look like ':9445, domain:9445 {'"
  fi
  if grep -q 'bind 127.0.0.1' /etc/caddy-nh/Caddyfile; then
    ok "Caddy backend is bound to 127.0.0.1"
  else
    warn "Caddy backend bind 127.0.0.1 not found"
  fi
fi

echo
echo "Access hints"
echo "------------"
if [[ "$PANEL_MODE" == "ssh-only" ]]; then
  echo "N+H panel via SSH tunnel:"
  echo "  ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${server_ip:-SERVER_IP}"
  echo "  http://127.0.0.1:${PANEL_PORT}"
elif [[ "$PANEL_MODE" == "allow-ip" ]]; then
  echo "N+H panel allowed only from ${ALLOW_PANEL_FROM}: http://${server_ip:-SERVER_IP}:${PANEL_PORT}"
else
  echo "N+H panel remains public: http://${server_ip:-SERVER_IP}:${PANEL_PORT}"
fi

echo
if [[ "$APPLY" -eq 1 ]]; then
  ok "Security hardening completed"
else
  info "Dry-run complete. Re-run with --apply --yes to make changes."
fi
