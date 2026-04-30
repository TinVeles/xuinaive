#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN=""
EMAIL=""
LISTEN_HOST="127.0.0.1"
LISTEN_PORT="9444"
SERVICE_NAME="caddy-naive"
CADDY_BIN="/usr/bin/caddy-naive"
CADDY_DIR="/etc/caddy-naive"

usage() {
  cat <<'EOF'
Usage:
  ./install-unified-backend.sh --domain n.example.com --email admin@example.com [--listen 127.0.0.1:9444]

Installs NaiveProxy/Caddy as a loopback backend for nginx stream SNI routing.
It does not bind public 0.0.0.0:443.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }

random_alpha() {
  local value
  set +o pipefail
  value="$(tr -dc 'A-Za-z' < /dev/urandom | head -c "$1")"
  set -o pipefail
  printf '%s\n' "$value"
}

random_alnum() {
  local value
  set +o pipefail
  value="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1")"
  set -o pipefail
  printf '%s\n' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --listen)
      listen_value="${2:-}"
      LISTEN_HOST="${listen_value%:*}"
      LISTEN_PORT="${listen_value##*:}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$EMAIL" ]] || die "--email is required"
[[ -n "$LISTEN_HOST" && -n "$LISTEN_PORT" ]] || die "--listen must be host:port"

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$CADDY_DIR" "/etc/systemd/system/${SERVICE_NAME}.service" "$CADDY_BIN"; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
info "Backup directory: $backup_dir"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wget curl tar libcap2-bin ca-certificates

if ! command -v go >/dev/null 2>&1; then
  info "Installing Go toolchain"
  rm -rf /usr/local/go
  wget https://go.dev/dl/go1.22.1.linux-amd64.tar.gz -O /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  export PATH="$PATH:/usr/local/go/bin"
else
  export PATH="$PATH:$(dirname "$(command -v go)")"
fi

export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
info "Building Caddy with NaiveProxy forwardproxy module"
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
tmp_build="$(mktemp -d)"
(
  cd "$tmp_build"
  /root/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
  chmod +x caddy
  mv caddy "$CADDY_BIN"
)
rm -rf "$tmp_build"
setcap cap_net_bind_service=+ep "$CADDY_BIN" || warn "setcap failed; service may still work on non-privileged backend port"

groupadd --system caddy 2>/dev/null || true
useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
mkdir -p "$CADDY_DIR"

USERNAME="$(random_alpha 14)"
PASSWORD="$(random_alnum 18)"

cat > "$CADDY_DIR/Caddyfile" <<EOF
{
    debug
    order forward_proxy before reverse_proxy
    auto_https disable_redirects
}

https://${DOMAIN}:${LISTEN_PORT} {
    bind ${LISTEN_HOST}
    tls ${EMAIL}

    forward_proxy {
        basic_auth ${USERNAME} ${PASSWORD}
        hide_ip
        hide_via
        probe_resistance
    }

    reverse_proxy https://kernel.org {
        header_up Host {upstream_hostport}
    }
}
EOF
chmod 600 "$CADDY_DIR/Caddyfile"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Caddy NaiveProxy Backend
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${CADDY_BIN} run --environ --config ${CADDY_DIR}/Caddyfile
ExecReload=${CADDY_BIN} reload --config ${CADDY_DIR}/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "$SERVICE_NAME is active on ${LISTEN_HOST}:${LISTEN_PORT}"
else
  die "$SERVICE_NAME failed. Check: journalctl -u ${SERVICE_NAME} --no-pager -n 50"
fi

cat <<EOF

NaiveProxy backend credentials
------------------------------
Domain:   ${DOMAIN}
Port:     443 via nginx SNI router, backend ${LISTEN_HOST}:${LISTEN_PORT}
Username: ${USERNAME}
Password: ${PASSWORD}

Client JSON example:
{
  "listen": "socks://127.0.0.1:1080",
  "proxy": "https://${USERNAME}:${PASSWORD}@${DOMAIN}"
}
EOF
