#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-${NAIVE_EMAIL:-}}"
LISTEN="${NAIVE_LISTEN:-127.0.0.1:9444}"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --domain n.example.com --email admin@example.com [--listen 127.0.0.1:9444]

This is the unified NaiveProxy installer wrapper.
It intentionally does not bind public 0.0.0.0:443.
It installs Caddy/NaiveProxy as a backend for nginx stream SNI routing.

The upstream original script is saved as install.upstream-original.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --listen) LISTEN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  read -r -p "Enter NaiveProxy domain: " DOMAIN
fi
if [[ -z "$EMAIL" ]]; then
  read -r -p "Enter email for Caddy/Let's Encrypt: " EMAIL
fi

bash "$SCRIPT_DIR/install-unified-backend.sh" --domain "$DOMAIN" --email "$EMAIL" --listen "$LISTEN"

