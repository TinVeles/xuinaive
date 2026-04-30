#!/usr/bin/env bash
set -Eeuo pipefail

NAIVE_DOMAIN=""
NAIVE_BACKEND="127.0.0.1:9444"
STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"

usage() {
  cat <<'EOF'
Usage:
  ./apply-naive-sni-route.sh --naive-domain n.example.com [--backend 127.0.0.1:9444]
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --naive-domain) NAIVE_DOMAIN="${2:-}"; shift 2 ;;
    --backend) NAIVE_BACKEND="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required"
[[ -f "$STREAM_CONF" ]] || die "nginx stream config not found: $STREAM_CONF"

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$STREAM_CONF" "$backup_dir/stream.conf"
info "Backup: $backup_dir/stream.conf"

tmp="$(mktemp)"
awk -v domain="$NAIVE_DOMAIN" -v backend="$NAIVE_BACKEND" '
  BEGIN {
    added_map = 0
    added_upstream = 0
    have_domain = 0
    have_upstream = 0
  }
  $0 ~ domain"[[:space:]]+naive;" { have_domain = 1 }
  $0 ~ /^upstream[[:space:]]+naive[[:space:]]*\{/ { have_upstream = 1 }
  {
    if (!have_upstream && !added_upstream && $0 ~ /^server[[:space:]]*\{/) {
      print ""
      print "upstream naive {"
      printf "    server %s;\n", backend
      print "}"
      print ""
      added_upstream = 1
    }
    print
    if (!have_domain && !added_map && $0 ~ /^[[:space:]]*hostnames;[[:space:]]*$/) {
      printf "    %s      naive;\n", domain
      added_map = 1
    }
  }
' "$STREAM_CONF" > "$tmp"

cat "$tmp" > "$STREAM_CONF"
rm -f "$tmp"

nginx -t
systemctl reload nginx
ok "NaiveProxy SNI route added: $NAIVE_DOMAIN -> $NAIVE_BACKEND"
