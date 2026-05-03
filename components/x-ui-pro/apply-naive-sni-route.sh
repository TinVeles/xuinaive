#!/usr/bin/env bash
set -Eeuo pipefail

ROUTE_DOMAIN=""
ROUTE_BACKEND="127.0.0.1:9445"
ROUTE_NAME="naive"
STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"

usage() {
  cat <<'EOF'
Usage:
  ./apply-naive-sni-route.sh --naive-domain n.example.com [--backend 127.0.0.1:9445]
  ./apply-naive-sni-route.sh --domain n.example.com --backend 127.0.0.1:9445 --name rixxx_naive
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) ROUTE_DOMAIN="${2:-}"; shift 2 ;;
    --naive-domain) ROUTE_DOMAIN="${2:-}"; ROUTE_NAME="naive"; shift 2 ;;
    --backend) ROUTE_BACKEND="${2:-}"; shift 2 ;;
    --name) ROUTE_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ -n "$ROUTE_DOMAIN" ]] || die "--domain or --naive-domain is required"
[[ "$ROUTE_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "--name must contain only letters, digits, and underscore"
[[ -f "$STREAM_CONF" ]] || die "nginx stream config not found: $STREAM_CONF"

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$STREAM_CONF" "$backup_dir/stream.conf"
info "Backup: $backup_dir/stream.conf"

tmp="$(mktemp)"
awk -v domain="$ROUTE_DOMAIN" -v backend="$ROUTE_BACKEND" -v route_name="$ROUTE_NAME" '
  BEGIN {
    added_map = 0
    added_upstream = 0
    have_domain = 0
    have_upstream = 0
  }
  index($0, domain) && index($0, route_name ";") { have_domain = 1 }
  $0 ~ "^upstream[[:space:]]+" route_name "[[:space:]]*\\{" { have_upstream = 1 }
  {
    if (!have_upstream && !added_upstream && $0 ~ /^server[[:space:]]*\{/) {
      print ""
      printf "upstream %s {\n", route_name
      printf "    server %s;\n", backend
      print "}"
      print ""
      added_upstream = 1
    }
    print
    if (!have_domain && !added_map && $0 ~ /^[[:space:]]*hostnames;[[:space:]]*$/) {
      printf "    %s      %s;\n", domain, route_name
      added_map = 1
    }
  }
' "$STREAM_CONF" > "$tmp"

cat "$tmp" > "$STREAM_CONF"
rm -f "$tmp"

nginx -t
systemctl reload nginx
ok "SNI route added: $ROUTE_DOMAIN -> $ROUTE_BACKEND ($ROUTE_NAME)"
