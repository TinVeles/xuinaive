#!/usr/bin/env bash
set -Eeuo pipefail

echo "STEP:1 install prerequisites"
export DEBIAN_FRONTEND=noninteractive

MIERU_VERSION="${MIERU_VERSION:-3.32.0}"
MIERU_LOGIN="${MIERU_LOGIN:-}"
MIERU_PASSWORD="${MIERU_PASSWORD:-}"
MIERU_PORT="${MIERU_PORT:-}"
MIERU_PROTOCOL="${MIERU_PROTOCOL:-TCP}"
MIERU_CONFIG="${MIERU_CONFIG:-/etc/mieru/server_config.json}"

die() { echo "ERROR: $*" >&2; exit 1; }
is_valid_user() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; }
is_valid_password() { [[ ${#1} -ge 8 && ${#1} -le 128 && "$1" =~ ^[A-Za-z0-9\!@#\$%\^\&\*_\+\-=.,~]+$ ]]; }
is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1025 && "$1" <= 65535 )); }

is_valid_user "$MIERU_LOGIN" || die "bad MIERU_LOGIN"
is_valid_password "$MIERU_PASSWORD" || die "bad MIERU_PASSWORD"
is_valid_port "$MIERU_PORT" || die "bad MIERU_PORT"
MIERU_PROTOCOL="${MIERU_PROTOCOL^^}"
[[ "$MIERU_PROTOCOL" == "TCP" || "$MIERU_PROTOCOL" == "UDP" ]] || die "bad MIERU_PROTOCOL"

if ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl ca-certificates
fi

echo "STEP:4 download mita"
arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) pkg_arch="amd64" ;;
  arm64) pkg_arch="arm64" ;;
  *) die "unsupported architecture: $arch" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/mita_${MIERU_VERSION}_${pkg_arch}.deb"
curl -fL --retry 3 -o "$pkg" "https://github.com/enfein/mieru/releases/download/v${MIERU_VERSION}/mita_${MIERU_VERSION}_${pkg_arch}.deb"

echo "STEP:5 install package"
dpkg -i "$pkg" || apt-get install -f -y

echo "STEP:6 write config"
mkdir -p "$(dirname "$MIERU_CONFIG")"
MIERU_LOGIN="$MIERU_LOGIN" MIERU_PASSWORD="$MIERU_PASSWORD" MIERU_PORT="$MIERU_PORT" MIERU_PROTOCOL="$MIERU_PROTOCOL" MIERU_CONFIG="$MIERU_CONFIG" node <<'NODE'
const fs = require('fs');
const cfg = {
  portBindings: [{ port: Number(process.env.MIERU_PORT), protocol: process.env.MIERU_PROTOCOL }],
  users: [{ name: process.env.MIERU_LOGIN, password: process.env.MIERU_PASSWORD }],
  loggingLevel: 'INFO',
  mtu: 1400
};
fs.writeFileSync(process.env.MIERU_CONFIG, JSON.stringify(cfg, null, 2), { mode: 0o600 });
try { fs.chmodSync(process.env.MIERU_CONFIG, 0o600); } catch {}
NODE

echo "STEP:7 apply config"
mita apply config "$MIERU_CONFIG"

echo "STEP:8 start service"
mita stop >/dev/null 2>&1 || true
mita start
systemctl enable mita >/dev/null 2>&1 || true

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  proto="$(printf '%s' "$MIERU_PROTOCOL" | tr '[:upper:]' '[:lower:]')"
  ufw allow "${MIERU_PORT}/${proto}" >/dev/null 2>&1 || true
fi

mita status || true
echo "STEP:DONE Mieru/mita installed"
