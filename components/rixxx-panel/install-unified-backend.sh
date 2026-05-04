#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_DIR="$SCRIPT_DIR/upstream"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOMAIN=""
EMAIL=""
PANEL_DOMAIN=""
PANEL_EMAIL=""
PANEL_ACCESS="nginx8080"
LISTEN_HOST="0.0.0.0"
INTERNAL_PORT="3000"
PANEL_PUBLIC_PORT="8081"
CADDY_LISTEN="127.0.0.1:9445"
CADDY_SERVICE="caddy-rixxx"
CADDY_BIN="/usr/bin/caddy-rixxx"
CADDY_DIR="/etc/caddy-rixxx"
PANEL_DIR="/opt/panel-naive-hy2"
TLS_CERT=""
TLS_KEY=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified-backend.sh --domain naive.example.com --email admin@example.com [--panel-public-port 8081]
  sudo ./install-unified-backend.sh --domain naive.example.com --email admin@example.com --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem

Installs RIXXX Panel + NaiveProxy + Hysteria2 as a backend for the x-ui-pro nginx stream layout:
- nginx owns public 443/tcp;
- caddy-rixxx listens on 127.0.0.1:9445 for NaiveProxy;
- Hysteria2 listens on public 443/udp;
- panel-naive-hy2 listens on 3000 and can be exposed through nginx on 8081.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }

fail_service() {
  local svc="$1"
  printf 'ERROR: %s failed to start\n' "$svc" >&2
  journalctl -u "$svc" -n 80 --no-pager -l >&2 || true
  exit 1
}

require_active() {
  local svc="$1"
  if ! systemctl is-active --quiet "$svc"; then
    fail_service "$svc"
  fi
  ok "$svc is active"
}

wait_http() {
  local url="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-1}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 3 "$url" >/dev/null; then
      ok "$label is responding at $url"
      return 0
    fi
    sleep "$delay"
  done

  printf 'ERROR: %s is not responding at %s\n' "$label" "$url" >&2
  if [[ "$label" == *"RIXXX panel"* ]]; then
    journalctl -u panel-naive-hy2 -n 80 --no-pager -l >&2 || true
  fi
  return 1
}

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
    --panel-domain) PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --panel-email) PANEL_EMAIL="${2:-}"; shift 2 ;;
    --panel-access) PANEL_ACCESS="${2:-}"; shift 2 ;;
    --panel-public-port) PANEL_PUBLIC_PORT="${2:-}"; shift 2 ;;
    --listen) CADDY_LISTEN="${2:-}"; shift 2 ;;
    --panel-listen-host) LISTEN_HOST="${2:-}"; shift 2 ;;
    --tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key) TLS_KEY="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$EMAIL" ]] || die "--email is required"
[[ -d "$UPSTREAM_DIR/panel" ]] || die "Missing vendored RIXXX panel: $UPSTREAM_DIR/panel"
if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
  [[ -f "$TLS_CERT" ]] || die "--tls-cert file not found: $TLS_CERT"
  [[ -f "$TLS_KEY" ]] || die "--tls-key file not found: $TLS_KEY"
fi

CADDY_HOST="${CADDY_LISTEN%:*}"
CADDY_PORT="${CADDY_LISTEN##*:}"
[[ -n "$CADDY_HOST" && -n "$CADDY_PORT" ]] || die "--listen must be host:port"
[[ -n "$PANEL_EMAIL" ]] || PANEL_EMAIL="$EMAIL"

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
for path in "$CADDY_DIR" "$PANEL_DIR" /etc/hysteria "/etc/systemd/system/${CADDY_SERVICE}.service" /etc/systemd/system/panel-naive-hy2.service /etc/systemd/system/hysteria-server.service; do
  if [[ -e "$path" || -L "$path" ]]; then
    mkdir -p "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$(dirname "$path")/"
  fi
done
info "Backup directory: $backup_dir"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl wget git openssl ufw ca-certificates jq build-essential libcap2-bin nginx

if ! command -v node >/dev/null 2>&1 || ! node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 18 ? 0 : 1)" 2>/dev/null; then
  info "Installing Node.js 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

if ! command -v go >/dev/null 2>&1; then
  info "Installing Go toolchain"
  case "$(uname -m)" in
    x86_64) GO_ARCH="amd64" ;;
    aarch64) GO_ARCH="arm64" ;;
    armv7l) GO_ARCH="armv6l" ;;
    *) GO_ARCH="amd64" ;;
  esac
  rm -rf /usr/local/go
  wget "https://go.dev/dl/go1.22.5.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
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
setcap cap_net_bind_service=+ep "$CADDY_BIN" || true

NAIVE_LOGIN="$(random_alpha 14)"
NAIVE_PASS="$(random_alnum 22)"
HY2_PASS="$(random_alnum 24)"
CREATED_AT="$(date -u +%FT%TZ)"

mkdir -p /var/www/html "$CADDY_DIR"
cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title></head><body>Loading</body></html>
EOF

cat > "$CADDY_DIR/Caddyfile" <<EOF
{
  auto_https disable_redirects
  order forward_proxy before file_server
  servers {
    protocols h1 h2
  }
}

https://${DOMAIN}:${CADDY_PORT} {
  bind ${CADDY_HOST}
  tls ${TLS_CERT:-$EMAIL}${TLS_KEY:+ $TLS_KEY}

  forward_proxy {
    basic_auth ${NAIVE_LOGIN} ${NAIVE_PASS}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF

"$CADDY_BIN" validate --config "$CADDY_DIR/Caddyfile" || die "Invalid $CADDY_DIR/Caddyfile"

cat > "/etc/systemd/system/${CADDY_SERVICE}.service" <<EOF
[Unit]
Description=Caddy RIXXX NaiveProxy Backend
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=${CADDY_BIN} run --environ --config ${CADDY_DIR}/Caddyfile
ExecReload=${CADDY_BIN} reload --config ${CADDY_DIR}/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$CADDY_SERVICE"
systemctl restart "$CADDY_SERVICE"
require_active "$CADDY_SERVICE"

CADDY_CERT=""
if [[ -n "$TLS_CERT" ]]; then
  CADDY_CERT="$TLS_CERT"
  CADDY_KEY="$TLS_KEY"
else
  info "Waiting for Caddy certificate for $DOMAIN"
  for _ in $(seq 1 45); do
    CADDY_CERT="$(find /root/.local/share/caddy /var/lib/caddy/.local/share/caddy -type f -name "${DOMAIN}.crt" 2>/dev/null | head -1 || true)"
    [[ -n "$CADDY_CERT" && -f "${CADDY_CERT%.crt}.key" ]] && break
    sleep 2
  done
  if [[ -z "$CADDY_CERT" ]]; then
    warn "Certificate was not detected."
    warn "Reason: nginx owns public 80/443, while caddy-rixxx listens on ${CADDY_LISTEN}."
    warn "NaiveProxy/Hysteria2 may not work until TLS is fixed. Prefer --tls-cert and --tls-key."
  fi
fi

case "$(uname -m)" in
  x86_64) HY_ARCH="amd64" ;;
  aarch64) HY_ARCH="arm64" ;;
  armv7l) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac
HY_VERSION="$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | jq -r '.tag_name' 2>/dev/null || true)"
[[ -n "$HY_VERSION" && "$HY_VERSION" != "null" ]] || HY_VERSION="app/v2.5.2"
wget -q --timeout=120 "https://github.com/apernet/hysteria/releases/download/${HY_VERSION}/hysteria-linux-${HY_ARCH}" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
setcap cap_net_bind_service=+ep /usr/local/bin/hysteria || true

mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<EOF
listen: :443

auth:
  type: userpass
  userpass:
    default: "${HY2_PASS}"

masquerade:
  type: file
  file:
    dir: /var/www/html
EOF

if [[ -n "$CADDY_CERT" ]]; then
  CADDY_KEY="${CADDY_KEY:-${CADDY_CERT%.crt}.key}"
  chmod -R 755 "$(dirname "$(dirname "$(dirname "$CADDY_CERT")")")" 2>/dev/null || true
  chmod 644 "$CADDY_CERT" 2>/dev/null || true
  chmod 640 "$CADDY_KEY" 2>/dev/null || true
  cat >> /etc/hysteria/config.yaml <<EOF

tls:
  cert: ${CADDY_CERT}
  key: ${CADDY_KEY}
EOF
else
  cat >> /etc/hysteria/config.yaml <<EOF

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  ca: letsencrypt
  listenHost: 0.0.0.0
EOF
fi

cat >> /etc/hysteria/config.yaml <<'EOF'

ignoreClientBandwidth: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
EOF

cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria2 Server (RIXXX unified)
After=network.target network-online.target caddy-rixxx.service
Wants=caddy-rixxx.service
Requires=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server || true
require_active hysteria-server

rm -rf "$PANEL_DIR"
mkdir -p "$PANEL_DIR"
cp -a "$UPSTREAM_DIR/." "$PANEL_DIR/"
[[ -d "$PANEL_DIR" ]] || die "ERROR: $PANEL_DIR was not created"
cd "$PANEL_DIR/panel"
npm install --omit=dev
mkdir -p "$PANEL_DIR/panel/data"
cat > "$PANEL_DIR/panel/data/config.json" <<EOF
{
  "installed": true,
  "stack": {
    "naive": true,
    "hy2": true
  },
  "domain": "${DOMAIN}",
  "email": "${EMAIL}",
  "panelDomain": "${PANEL_DOMAIN}",
  "panelEmail": "${PANEL_EMAIL}",
  "accessMode": "${PANEL_ACCESS}",
  "sshOnly": 0,
  "listenHost": "${LISTEN_HOST}",
  "masqueradeMode": "local",
  "masqueradeUrl": "",
  "serverIp": "",
  "arch": "$(uname -m)",
  "naiveUsers": [
    {
      "username": "${NAIVE_LOGIN}",
      "password": "${NAIVE_PASS}",
      "createdAt": "${CREATED_AT}"
    }
  ],
  "hy2Users": [
    {
      "username": "default",
      "password": "${HY2_PASS}",
      "createdAt": "${CREATED_AT}"
    }
  ]
}
EOF
chmod 600 "$PANEL_DIR/panel/data/config.json"

cat > /etc/systemd/system/panel-naive-hy2.service <<EOF
[Unit]
Description=RIXXX Panel Naive + Hysteria2
After=network.target ${CADDY_SERVICE}.service hysteria-server.service

[Service]
Type=simple
WorkingDirectory=${PANEL_DIR}/panel
Environment=NODE_ENV=production
Environment=PORT=${INTERNAL_PORT}
Environment=LISTEN_HOST=${LISTEN_HOST}
Environment=CADDY_SERVICE=${CADDY_SERVICE}
Environment=CADDYFILE_PATH=${CADDY_DIR}/Caddyfile
Environment=CADDY_SITE_TEMPLATE=https://{domain}:${CADDY_PORT}
Environment=CADDY_BIND=${CADDY_HOST}
ExecStart=/usr/bin/node server/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable panel-naive-hy2
systemctl restart panel-naive-hy2
require_active panel-naive-hy2

if [[ "$PANEL_ACCESS" == "nginx8080" ]]; then
  cat > /etc/nginx/sites-available/panel-naive-hy2 <<EOF
server {
    listen ${PANEL_PUBLIC_PORT};
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/panel-naive-hy2 /etc/nginx/sites-enabled/panel-naive-hy2
  nginx -t || die "nginx config test failed after panel proxy creation"
  systemctl reload nginx || die "nginx reload failed after panel proxy creation"
fi

wait_http "http://127.0.0.1:${INTERNAL_PORT}/" "RIXXX panel backend" 45 1 || die "RIXXX panel is not responding on 127.0.0.1:${INTERNAL_PORT}"
if [[ "$PANEL_ACCESS" == "nginx8080" ]]; then
  wait_http "http://127.0.0.1:${PANEL_PUBLIC_PORT}/" "RIXXX panel nginx proxy" 30 1 || die "RIXXX panel is not available through nginx on 127.0.0.1:${PANEL_PUBLIC_PORT}"
fi

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
[[ "$PANEL_ACCESS" == "nginx8080" ]] && ufw allow "${PANEL_PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true

mkdir -p /etc/rixxx-panel
echo "1.4.0-unified" > /etc/rixxx-panel/version

cat > "$PROJECT_DIR/config.env" <<EOF
NAIVE_DOMAIN="${DOMAIN}"
RIXXX_PROXY_DOMAIN="${DOMAIN}"
RIXXX_PANEL_DOMAIN="${PANEL_DOMAIN}"
RIXXX_EMAIL="${EMAIL}"
RIXXX_PANEL_PORT="${PANEL_PUBLIC_PORT}"
RIXXX_BACKEND_LISTEN="${CADDY_LISTEN}"
EOF
ok "Saved RIXXX configuration: $PROJECT_DIR/config.env"

service_state() {
  systemctl is-active "$1" 2>/dev/null || true
}

cat <<EOF

RIXXX unified backend installed
-------------------------------

Panel:
  URL:   http://SERVER_IP:${PANEL_PUBLIC_PORT}
  Login: admin
  Pass:  admin

Links:
  Naive: naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${DOMAIN}:443
  Hy2:   hysteria2://default:${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&insecure=0#RIXXX

Services:
  ${CADDY_SERVICE}:     $(service_state "$CADDY_SERVICE")
  panel-naive-hy2:      $(service_state panel-naive-hy2)
  hysteria-server:      $(service_state hysteria-server)

Ports:
  panel backend:        ${LISTEN_HOST}:${INTERNAL_PORT}
  panel public:         0.0.0.0:${PANEL_PUBLIC_PORT}
  caddy backend:        ${CADDY_LISTEN}

Warnings:
  - Change default panel password admin/admin.
  - If ACME certificate was not issued, NaiveProxy/Hysteria2 may not work until TLS is fixed.
EOF
