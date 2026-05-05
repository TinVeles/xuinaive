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
LISTEN_HOST="127.0.0.1"
INTERNAL_PORT="3000"
PANEL_PUBLIC_PORT="8081"
CADDY_LISTEN="127.0.0.1:9445"
CADDY_SERVICE="caddy-nh"
CADDY_BIN="/usr/bin/caddy-nh"
CADDY_DIR="/etc/caddy-nh"
PANEL_DIR="/opt/panel-naive-hy2"
TLS_CERT=""
TLS_KEY=""

usage() {
  cat <<'EOF'
Usage:
  sudo ./install-unified-backend.sh --domain naive.example.com --email admin@example.com [--panel-public-port 8081]
  sudo ./install-unified-backend.sh --domain naive.example.com --email admin@example.com --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem

Installs N+H Panel + NaiveProxy + Hysteria2 as a backend for the x-ui-pro nginx stream layout:
- nginx owns public 443/tcp;
- caddy-nh listens on 127.0.0.1:9445 for NaiveProxy;
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
  if [[ "$label" == *"N+H panel"* ]]; then
    journalctl -u panel-naive-hy2 -n 80 --no-pager -l >&2 || true
    if [[ "$label" == *"nginx"* || "$label" == *"public"* ]]; then
      systemctl status nginx --no-pager -l >&2 || true
      nginx -T 2>/dev/null | grep -E 'panel-naive-hy2|listen|proxy_pass' >&2 || true
    fi
  fi
  return 1
}

public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  printf '%s\n' "$ip"
}

check_tls() {
  local target="$1"
  local server_name="$2"
  local label="$3"
  local output=""

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl is missing; skipping $label TLS check"
    return 0
  fi

  output="$(timeout 12 openssl s_client \
    -connect "$target" \
    -servername "$server_name" \
    -alpn http/1.1 \
    -brief </dev/null 2>&1 || true)"

  if grep -Eq 'Protocol version: TLSv1\.[23]' <<<"$output" && grep -q 'Verification: OK' <<<"$output"; then
    ok "$label TLS is valid for $server_name at $target"
    return 0
  fi

  printf 'ERROR: %s TLS check failed for %s at %s\n' "$label" "$server_name" "$target" >&2
  printf '%s\n' "$output" >&2
  return 1
}

restore_nginx_after_acme() {
  if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl start nginx >/dev/null 2>&1 || true
  fi
}

port80_busy_details() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp 'sport = :80' 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null || true
  fi
}

install_certbot_deploy_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/nh-unified-reload.sh <<EOF
#!/usr/bin/env bash
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
systemctl reload ${CADDY_SERVICE} >/dev/null 2>&1 || systemctl restart ${CADDY_SERVICE} >/dev/null 2>&1 || true
systemctl restart hysteria-server >/dev/null 2>&1 || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/nh-unified-reload.sh
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
[[ -d "$UPSTREAM_DIR/panel" ]] || die "Missing vendored N+H panel: $UPSTREAM_DIR/panel"
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
apt-get install -y curl wget git openssl ufw ca-certificates jq build-essential libcap2-bin nginx certbot gnupg

node_usable() {
  command -v node >/dev/null 2>&1 && node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 18 ? 0 : 1)" 2>/dev/null
}

if ! node_usable; then
  info "Installing distro Node.js"
  apt-get install -y nodejs npm || true
fi

if ! node_usable; then
  info "Installing Node.js 20"
  install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --yes --dearmor --output /usr/share/keyrings/nodesource.gpg
  cat > /etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main
EOF
  apt-get update
  apt-get install -y nodejs
fi
node_usable || die "Node.js 18+ is required"

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
PANEL_LOGIN="admin"
PANEL_PASSWORD="$(random_alnum 24)"
CREATED_AT="$(date -u +%FT%TZ)"

mkdir -p /var/www/html "$CADDY_DIR"
cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title></head><body>Loading</body></html>
EOF

if [[ -z "$TLS_CERT" && -z "$TLS_KEY" ]]; then
  info "Issuing TLS certificate for $DOMAIN through nginx HTTP-01"
  mkdir -p /var/www/html/.well-known/acme-challenge /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > /etc/nginx/sites-available/nh-acme <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/nh-acme /etc/nginx/sites-enabled/nh-acme
  nginx -t || die "nginx config test failed before ACME issuance"
  systemctl reload nginx || die "nginx reload failed before ACME issuance"

  if certbot certonly --webroot \
      -w /var/www/html \
      -d "$DOMAIN" \
      --email "$EMAIL" \
      --agree-tos \
      --non-interactive; then
    TLS_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    TLS_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    ok "Certificate issued: $TLS_CERT"
  else
    warn "nginx HTTP-01 issuance failed; trying automatic standalone fallback"
    systemctl stop "$CADDY_SERVICE" >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
    sleep 2

    busy80="$(port80_busy_details)"
    if [[ -n "$busy80" ]]; then
      restore_nginx_after_acme
      printf 'ERROR: port 80 is busy; standalone certificate issuance cannot continue.\n' >&2
      printf '%s\n' "$busy80" >&2
      die "Stop the process that owns port 80 or rerun with --tls-cert and --tls-key."
    fi

    if certbot certonly --standalone \
        --preferred-challenges http \
        --http-01-port 80 \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive; then
      TLS_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
      TLS_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
      ok "Certificate issued through standalone fallback: $TLS_CERT"
    else
      restore_nginx_after_acme
      die "Certificate was not issued automatically. Check DNS, public firewall for 80/tcp, and provider security groups."
    fi

    restore_nginx_after_acme
  fi
fi
[[ -f "$TLS_CERT" ]] || die "TLS cert is required for unified N+H backend: $TLS_CERT"
[[ -f "$TLS_KEY" ]] || die "TLS key is required for unified N+H backend: $TLS_KEY"
install_certbot_deploy_hook

cat > "$CADDY_DIR/Caddyfile" <<EOF
{
  auto_https disable_redirects
  order forward_proxy before file_server

  servers ${CADDY_HOST}:${CADDY_PORT} {
    listener_wrappers {
      proxy_protocol {
        timeout 2s
        allow 127.0.0.1/32
        fallback_policy skip
      }
      tls
    }
    protocols h1 h2
  }
}

:${CADDY_PORT}, ${DOMAIN}:${CADDY_PORT} {
  bind ${CADDY_HOST}
  tls ${TLS_CERT} ${TLS_KEY}

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
Description=Caddy N+H NaiveProxy Backend
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
check_tls "127.0.0.1:${CADDY_PORT}" "$DOMAIN" "Caddy backend" || die "Caddy backend TLS is not usable. Check cert/key and proxy_protocol listener wrapper."

CADDY_CERT=""
CADDY_CERT="$TLS_CERT"
CADDY_KEY="$TLS_KEY"

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
Description=Hysteria2 Server (N+H unified)
After=network.target network-online.target caddy-nh.service
Wants=caddy-nh.service
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
PANEL_LOGIN="$PANEL_LOGIN" PANEL_PASSWORD="$PANEL_PASSWORD" node <<'NODE'
const fs = require('fs');
const path = require('path');
const bcrypt = require('bcryptjs');
const dataDir = path.join(process.cwd(), 'data');
const usersFile = path.join(dataDir, 'users.json');
fs.mkdirSync(dataDir, { recursive: true });
const users = {};
users[process.env.PANEL_LOGIN || 'admin'] = {
  password: bcrypt.hashSync(process.env.PANEL_PASSWORD, 10),
  role: 'admin'
};
fs.writeFileSync(usersFile, JSON.stringify(users, null, 2), { mode: 0o600 });
NODE
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
  "tlsCert": "${TLS_CERT}",
  "tlsKey": "${TLS_KEY}",
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
Description=N+H Panel Naive + Hysteria2
After=network.target ${CADDY_SERVICE}.service hysteria-server.service

[Service]
Type=simple
WorkingDirectory=${PANEL_DIR}/panel
Environment=NODE_ENV=production
Environment=PORT=${INTERNAL_PORT}
Environment=LISTEN_HOST=${LISTEN_HOST}
Environment=CADDY_SERVICE=${CADDY_SERVICE}
Environment=CADDY_BIN=${CADDY_BIN}
Environment=CADDYFILE_PATH=${CADDY_DIR}/Caddyfile
Environment=CADDY_SITE_TEMPLATE=:${CADDY_PORT}, {domain}:${CADDY_PORT}
Environment=CADDY_BIND=${CADDY_HOST}
Environment=CADDY_LISTENER_SERVER=${CADDY_HOST}:${CADDY_PORT}
Environment=CADDY_PROXY_PROTOCOL=1
Environment=CADDY_TLS_CERT=${TLS_CERT}
Environment=CADDY_TLS_KEY=${TLS_KEY}
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
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx || die "nginx reload failed after panel proxy creation"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  check_tls "${DOMAIN}:443" "$DOMAIN" "Public nginx stream" || die "Public NaiveProxy TLS is not usable. Check nginx stream SNI route and PROXY protocol."
else
  warn "nginx is not active; skipping public TLS check for ${DOMAIN}:443"
fi

wait_http "http://127.0.0.1:${INTERNAL_PORT}/" "N+H panel backend" 45 1 || die "N+H panel is not responding on 127.0.0.1:${INTERNAL_PORT}"
if [[ "$PANEL_ACCESS" == "nginx8080" ]]; then
  wait_http "http://127.0.0.1:${PANEL_PUBLIC_PORT}/" "N+H panel nginx proxy" 30 1 || die "N+H panel is not available through nginx on 127.0.0.1:${PANEL_PUBLIC_PORT}"
fi

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
[[ "$PANEL_ACCESS" == "nginx8080" ]] && ufw allow "${PANEL_PUBLIC_PORT}/tcp" >/dev/null 2>&1 || true

if [[ "$PANEL_ACCESS" == "nginx8080" ]]; then
  SERVER_IP="$(public_ipv4)"
  if [[ -n "$SERVER_IP" ]]; then
    wait_http "http://${SERVER_IP}:${PANEL_PUBLIC_PORT}/" "N+H panel public access" 15 2 || {
      warn "N+H panel works locally but is not reachable through public IP ${SERVER_IP}:${PANEL_PUBLIC_PORT}."
      warn "The remaining blocker is usually a VPS provider firewall/security group for ${PANEL_PUBLIC_PORT}/tcp."
      die "N+H panel public URL check failed: http://${SERVER_IP}:${PANEL_PUBLIC_PORT}/"
    }
  else
    warn "Could not detect public IPv4; skipping public N+H panel URL check"
  fi
fi

mkdir -p /etc/nh-panel
echo "1.4.0-unified" > /etc/nh-panel/version

cat > "$PROJECT_DIR/config.env" <<EOF
NAIVE_DOMAIN="${DOMAIN}"
NH_PROXY_DOMAIN="${DOMAIN}"
NH_PANEL_DOMAIN="${PANEL_DOMAIN}"
NH_EMAIL="${EMAIL}"
NH_PANEL_PORT="${PANEL_PUBLIC_PORT}"
NH_BACKEND_LISTEN="${CADDY_LISTEN}"
NH_TLS_CERT="${TLS_CERT}"
NH_TLS_KEY="${TLS_KEY}"
NH_PANEL_URL="http://${SERVER_IP:-SERVER_IP}:${PANEL_PUBLIC_PORT}"
NH_PANEL_LOGIN="${PANEL_LOGIN}"
NH_PANEL_PASSWORD="${PANEL_PASSWORD}"
NH_NAIVE_LOGIN="${NAIVE_LOGIN}"
NH_NAIVE_PASSWORD="${NAIVE_PASS}"
NH_NAIVE_LINK="naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${DOMAIN}:443"
NH_HY2_USER="default"
NH_HY2_PASSWORD="${HY2_PASS}"
NH_HY2_LINK="hysteria2://default:${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&insecure=0#N+H"
EOF
ok "Saved N+H configuration: $PROJECT_DIR/config.env"

service_state() {
  local svc="$1"
  local state=""
  for _ in $(seq 1 10); do
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    [[ "$state" != "activating" ]] && break
    sleep 1
  done
  printf '%s\n' "$state"
}

cat <<EOF

N+H unified backend installed
-------------------------------

Panel:
  URL:   http://${SERVER_IP:-SERVER_IP}:${PANEL_PUBLIC_PORT}
  Login: ${PANEL_LOGIN}
  Pass:  ${PANEL_PASSWORD}

Links:
  Naive: naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${DOMAIN}:443
  Hy2:   hysteria2://default:${HY2_PASS}@${DOMAIN}:443?sni=${DOMAIN}&insecure=0#N+H

Services:
  ${CADDY_SERVICE}:     $(service_state "$CADDY_SERVICE")
  panel-naive-hy2:      $(service_state panel-naive-hy2)
  hysteria-server:      $(service_state hysteria-server)

Ports:
  panel backend:        ${LISTEN_HOST}:${INTERNAL_PORT}
  panel public:         0.0.0.0:${PANEL_PUBLIC_PORT}
  caddy backend:        ${CADDY_LISTEN}

Warnings:
  - Keep generated panel password private.
  - N+H/Naive TLS was checked locally and through public nginx stream during install.
EOF
