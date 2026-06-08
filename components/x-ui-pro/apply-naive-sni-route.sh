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

is_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ && ${#1} -le 253 ]]
}

is_valid_hostport() {
  local host="${1%:*}" port="${1##*:}"
  [[ -n "$host" && "$host" != "$1" ]] || return 1
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^localhost$|^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]
}

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
is_valid_domain "$ROUTE_DOMAIN" || die "--domain is invalid: $ROUTE_DOMAIN"
[[ "$ROUTE_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "--name must contain only letters, digits, and underscore"
is_valid_hostport "$ROUTE_BACKEND" || die "--backend must be safe host:port"
[[ -f "$STREAM_CONF" ]] || die "nginx stream config not found: $STREAM_CONF"

backup_dir="/opt/unified-proxy-manager/backups/$(date '+%Y-%m-%d-%H-%M-%S')"
mkdir -p "$backup_dir"
cp -a "$STREAM_CONF" "$backup_dir/stream.conf"
info "Backup: $backup_dir/stream.conf"

tmp="$(mktemp)"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

if ! awk -v domain="$ROUTE_DOMAIN" -v backend="$ROUTE_BACKEND" -v route_name="$ROUTE_NAME" '
  BEGIN {
    added_map = 0
    added_upstream = 0
    have_domain = 0
    have_upstream = 0
  }
  $1 == domain && $2 ~ /;$/ {
    printf "    %s      %s;\n", domain, route_name
    have_domain = 1
    next
  }
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
  END {
    if (!have_upstream && !added_upstream) {
      printf "missing server block anchor for upstream %s\n", route_name > "/dev/stderr"
      exit 20
    }
    if (!have_domain && !added_map) {
      printf "missing hostnames anchor for domain %s\n", domain > "/dev/stderr"
      exit 21
    }
  }
' "$STREAM_CONF" > "$tmp"; then
  cp "$backup_dir/stream.conf" "$STREAM_CONF"
  die "SNI route was not added; restored backup: $backup_dir/stream.conf"
fi

cp "$tmp" "$STREAM_CONF"
if ! nginx -t; then
  cp "$backup_dir/stream.conf" "$STREAM_CONF"
  nginx -t >/dev/null 2>&1 || true
  die "nginx config test failed; restored backup: $backup_dir/stream.conf"
fi

systemctl reload nginx
ok "SNI route added: $ROUTE_DOMAIN -> $ROUTE_BACKEND ($ROUTE_NAME)"
