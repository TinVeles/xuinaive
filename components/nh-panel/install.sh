#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_DIR="$SCRIPT_DIR/upstream"
UPSTREAM_INSTALL="$UPSTREAM_DIR/install.sh"

STACK="${NH_STACK:-both}"
ACCESS="${NH_ACCESS:-nginx8080}"
PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
PROXY_EMAIL="${NH_PROXY_EMAIL:-${PROXY_EMAIL:-}}"
PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
PANEL_EMAIL="${NH_PANEL_EMAIL:-${PANEL_EMAIL:-}}"
SSH_ONLY="${NH_SSH_ONLY:-0}"
MASQUERADE="${NH_MASQUERADE:-local}"
MASQUERADE_URL="${NH_MASQUERADE_URL:-}"
ASSUME_YES=0
DRY_RUN=0
ALLOW_PORT_CONFLICT=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./components/nh-panel/install.sh --domain vpn.example.com --email admin@example.com --yes

Options:
  --stack both|naive|hy2
  --access nginx8080|direct3000|subdomain
  --domain DOMAIN
  --email EMAIL
  --panel-domain DOMAIN        Required with --access subdomain
  --panel-email EMAIL          Optional with --access subdomain
  --ssh-only
  --masquerade local|mirror
  --masquerade-url URL         Required with --masquerade mirror
  --allow-port-conflict        Continue even if public 443 already has a listener
  --dry-run
  --yes

Without --yes, this wrapper starts the original interactive installer.
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) STACK="${2:-}"; shift 2 ;;
    --access) ACCESS="${2:-}"; shift 2 ;;
    --domain|--proxy-domain) PROXY_DOMAIN="${2:-}"; shift 2 ;;
    --email|--proxy-email) PROXY_EMAIL="${2:-}"; shift 2 ;;
    --panel-domain) PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --panel-email) PANEL_EMAIL="${2:-}"; shift 2 ;;
    --ssh-only) SSH_ONLY=1; shift ;;
    --masquerade) MASQUERADE="${2:-}"; shift 2 ;;
    --masquerade-url) MASQUERADE_URL="${2:-}"; shift 2 ;;
    --allow-port-conflict) ALLOW_PORT_CONFLICT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "$UPSTREAM_INSTALL" ]] || die "Missing upstream installer: $UPSTREAM_INSTALL"

stack_answer() {
  case "$STACK" in
    naive|1) printf '1\n' ;;
    hy2|hysteria|hysteria2|2) printf '2\n' ;;
    both|3) printf '3\n' ;;
    *) die "--stack must be both, naive, or hy2" ;;
  esac
}

access_answer() {
  case "$ACCESS" in
    nginx|nginx8080|8080|1) printf '1\n' ;;
    direct|direct3000|3000|2) printf '2\n' ;;
    subdomain|domain|panel-domain|3) printf '3\n' ;;
    *) die "--access must be nginx8080, direct3000, or subdomain" ;;
  esac
}

masquerade_answer() {
  case "$MASQUERADE" in
    local|1) printf '1\n' ;;
    mirror|2) printf '2\n' ;;
    *) die "--masquerade must be local or mirror" ;;
  esac
}

port_443_busy() {
  if command_exists ss; then
    ss -H -ltnup "sport = :443" 2>/dev/null | grep -q .
  elif command_exists lsof; then
    lsof -nP -iTCP:443 -sTCP:LISTEN 2>/dev/null | grep -q .
  else
    return 1
  fi
}

if [[ "$ASSUME_YES" != "1" ]]; then
  warn "Starting the original interactive N+H installer."
  warn "It installs a public Caddy/NaiveProxy/Hy2 stack and can change packages, firewall, services, and /etc configs."
  export LOCAL_PANEL_SOURCE="$UPSTREAM_DIR"
  exec bash "$UPSTREAM_INSTALL"
fi

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$PROXY_DOMAIN" ]] || die "--domain is required with --yes"
[[ -n "$PROXY_EMAIL" ]] || die "--email is required with --yes"

STACK_ANSWER="$(stack_answer)"
ACCESS_ANSWER="$(access_answer)"
MASQUERADE_ANSWER="$(masquerade_answer)"

if [[ "$ACCESS_ANSWER" == "3" ]]; then
  [[ -n "$PANEL_DOMAIN" ]] || die "--panel-domain is required with --access subdomain"
  [[ -n "$PANEL_EMAIL" ]] || PANEL_EMAIL="$PROXY_EMAIL"
fi

if [[ "$MASQUERADE_ANSWER" == "2" ]]; then
  [[ -n "$MASQUERADE_URL" ]] || die "--masquerade-url is required with --masquerade mirror"
fi

if port_443_busy && [[ "$ALLOW_PORT_CONFLICT" != "1" ]]; then
  die "Port 443 already has a listener. Stop the conflicting service or rerun with --allow-port-conflict after review."
fi

cat <<EOF
N+H panel install plan
------------------------
Stack:       $STACK
Access:      $ACCESS
Proxy domain: $PROXY_DOMAIN
Proxy email:  $PROXY_EMAIL
Panel domain: ${PANEL_DOMAIN:-not used}
SSH-only:    $SSH_ONLY
Masquerade:  $MASQUERADE ${MASQUERADE_URL:-}

This will run the vendored N+H installer with LOCAL_PANEL_SOURCE=$UPSTREAM_DIR.
EOF

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

{
  printf '%s\n' "$STACK_ANSWER"
  printf '%s\n' "$ACCESS_ANSWER"
  if [[ "$ACCESS_ANSWER" == "3" ]]; then
    printf '%s\n' "$PANEL_DOMAIN"
    printf '%s\n' "$PANEL_EMAIL"
  fi
  if [[ "$SSH_ONLY" == "1" ]]; then
    printf 'y\n'
    if [[ "$ACCESS_ANSWER" == "3" ]]; then
      printf 'y\n'
    fi
  else
    printf 'n\n'
  fi
  printf '%s\n' "$PROXY_DOMAIN"
  printf '%s\n' "$PROXY_EMAIL"
  printf '%s\n' "$MASQUERADE_ANSWER"
  if [[ "$MASQUERADE_ANSWER" == "2" ]]; then
    printf '%s\n' "$MASQUERADE_URL"
  fi
  printf '\n'
} | LOCAL_PANEL_SOURCE="$UPSTREAM_DIR" bash "$UPSTREAM_INSTALL"
