#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-inbound-443}"
WARP_ROUTE_PORT="${WARP_ROUTE_PORT:-443}"
WARP_SNIPPET_DIR="${WARP_SNIPPET_DIR:-/etc/x-ui}"
ASSUME_YES=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { printf '%s\n' "${BLUE}INFO:${NC} $*"; }
ok() { printf '%s\n' "${GREEN}OK:${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${NC} $*"; }
err() { printf '%s\n' "${RED}ERROR:${NC} $*" >&2; }
die() { err "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage:
  sudo bash install-warp.sh --yes
  sudo bash install-warp.sh --proxy-port 40000 --outbound-tag warp-cli --inbound-tag inbound-443 --route-port 443 --yes

Installs Cloudflare WARP in local proxy mode and prepares 3x-ui/Xray snippets:
  SOCKS/HTTP proxy: 127.0.0.1:${WARP_PROXY_PORT}
  Xray outbound tag: ${WARP_OUTBOUND_TAG}
  Routing rule: inboundTag=${WARP_INBOUND_TAG}, port=${WARP_ROUTE_PORT}, outboundTag=${WARP_OUTBOUND_TAG}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --outbound-tag) WARP_OUTBOUND_TAG="${2:-}"; shift 2 ;;
    --inbound-tag) WARP_INBOUND_TAG="${2:-}"; shift 2 ;;
    --route-port) WARP_ROUTE_PORT="${2:-}"; shift 2 ;;
    --snippet-dir) WARP_SNIPPET_DIR="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$ASSUME_YES" == "1" ]] || die "Add --yes after reading what this script changes"
[[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--proxy-port must be numeric"
[[ "$WARP_ROUTE_PORT" =~ ^[0-9]+$ ]] || die "--route-port must be numeric"

if [[ ! -r /etc/os-release ]]; then
  die "/etc/os-release not found"
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Cloudflare WARP apt install is supported here only for Ubuntu/Debian. Detected: ${PRETTY_NAME:-unknown}" ;;
esac

codename="${VERSION_CODENAME:-}"
if [[ -z "$codename" ]] && command_exists lsb_release; then
  codename="$(lsb_release -cs)"
fi
[[ -n "$codename" ]] || die "Could not detect distro codename"

info "Installing Cloudflare WARP apt repository"
apt-get update
apt-get install -y ca-certificates curl gpg lsb-release
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

info "Installing cloudflare-warp package"
apt-get update
apt-get install -y cloudflare-warp

systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl restart warp-svc >/dev/null 2>&1 || true
sleep 2
command_exists warp-cli || die "warp-cli was not installed"

warp() {
  warp-cli --accept-tos "$@" 2>/dev/null || warp-cli "$@"
}

info "Registering WARP client if needed"
if warp registration show >/dev/null 2>&1 || warp account >/dev/null 2>&1; then
  ok "WARP registration already exists"
else
  warp registration new >/dev/null 2>&1 || warp register >/dev/null 2>&1 || die "WARP registration failed"
fi

info "Switching WARP to local proxy mode"
warp mode proxy >/dev/null 2>&1 || warp set-mode proxy >/dev/null 2>&1 || die "Could not switch WARP to proxy mode"

if warp proxy port "$WARP_PROXY_PORT" >/dev/null 2>&1; then
  ok "WARP proxy port set to $WARP_PROXY_PORT"
elif warp set-proxy-port "$WARP_PROXY_PORT" >/dev/null 2>&1; then
  ok "WARP proxy port set to $WARP_PROXY_PORT"
else
  warn "Could not explicitly set WARP proxy port. Continuing with expected default ${WARP_PROXY_PORT}."
fi

info "Connecting WARP"
warp connect >/dev/null 2>&1 || die "WARP connect failed"
sleep 4

status_text="$(warp status 2>/dev/null || true)"
printf '%s\n' "$status_text"
if grep -qi "connected" <<<"$status_text"; then
  ok "WARP status is connected"
else
  warn "WARP status did not clearly say connected"
fi

if command_exists ss && ss -H -ltn "sport = :$WARP_PROXY_PORT" 2>/dev/null | grep -q .; then
  ok "WARP local proxy is listening on port $WARP_PROXY_PORT"
else
  warn "Could not confirm listener on port $WARP_PROXY_PORT"
fi

if command_exists curl; then
  info "Testing WARP local proxy with Cloudflare trace"
  if curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace | tee /tmp/warp-trace.txt; then
    if grep -qi '^warp=on' /tmp/warp-trace.txt; then
      ok "Cloudflare trace reports warp=on"
    else
      warn "Cloudflare trace completed but did not report warp=on. Check /tmp/warp-trace.txt"
    fi
  else
    warn "Proxy curl test failed. WARP may still be starting; run: curl --socks5-hostname 127.0.0.1:${WARP_PROXY_PORT} https://www.cloudflare.com/cdn-cgi/trace"
  fi
fi

mkdir -p "$WARP_SNIPPET_DIR"
snippet_file="$WARP_SNIPPET_DIR/warp-xray-snippets.json"
cat > "$snippet_file" <<EOF
{
  "outbound": {
    "tag": "${WARP_OUTBOUND_TAG}",
    "protocol": "socks",
    "settings": {
      "servers": [
        {
          "address": "127.0.0.1",
          "port": ${WARP_PROXY_PORT}
        }
      ]
    }
  },
  "routingRule": {
    "type": "field",
    "inboundTag": [
      "${WARP_INBOUND_TAG}"
    ],
    "port": "${WARP_ROUTE_PORT}",
    "outboundTag": "${WARP_OUTBOUND_TAG}"
  }
}
EOF
chmod 0644 "$snippet_file"
ok "Saved Xray/3x-ui snippets: $snippet_file"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  tmp_config="$(mktemp)"
  grep -vE '^(WARP_ENABLED|WARP_PROXY_HOST|WARP_PROXY_PORT|WARP_OUTBOUND_TAG|WARP_INBOUND_TAG|WARP_ROUTE_PORT|WARP_SNIPPET_FILE)=' "$SCRIPT_DIR/config.env" > "$tmp_config" || true
  cat >> "$tmp_config" <<EOF
WARP_ENABLED="1"
WARP_PROXY_HOST="127.0.0.1"
WARP_PROXY_PORT="${WARP_PROXY_PORT}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG}"
WARP_ROUTE_PORT="${WARP_ROUTE_PORT}"
WARP_SNIPPET_FILE="${snippet_file}"
EOF
  install -m 0600 "$tmp_config" "$SCRIPT_DIR/config.env"
  rm -f "$tmp_config"
  ok "Updated project config.env with WARP values"
fi

cat <<EOF

WARP installed
--------------
Local proxy:
  SOCKS/HTTP: 127.0.0.1:${WARP_PROXY_PORT}

3x-ui / Xray values:
  Outbound protocol: socks
  Outbound tag:      ${WARP_OUTBOUND_TAG}
  Address:           127.0.0.1
  Port:              ${WARP_PROXY_PORT}
  Routing inbound:   ${WARP_INBOUND_TAG}
  Routing port:      ${WARP_ROUTE_PORT}
  Routing outbound:  ${WARP_OUTBOUND_TAG}

Snippet file:
  ${snippet_file}

Useful checks:
  warp-cli --accept-tos status
  curl --socks5-hostname 127.0.0.1:${WARP_PROXY_PORT} https://www.cloudflare.com/cdn-cgi/trace
EOF
