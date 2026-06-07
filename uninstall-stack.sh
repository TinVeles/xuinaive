#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
ASSUME_YES=0
REMOVE_WARP=0
BACKUP_ROOT="${BACKUP_ROOT:-/opt/unified-proxy-manager/backups}"

XUI_DOMAIN="${XUI_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"

usage() {
  cat <<'EOF'
Usage:
  sudo bash uninstall-stack.sh
  sudo bash uninstall-stack.sh --apply --yes
  sudo bash uninstall-stack.sh --apply --yes --remove-warp

Removes the installed x-ui + Naive panel stack while preserving certificates:
  kept: certificate stores under /etc/letsencrypt, /root/cert, /var/lib/caddy, /root/.local/share/caddy
  removed: x-ui, RIXXX/NHM panel files, caddy-naive/caddy-nh, hysteria config, stack systemd units, stack nginx snippets/sites

Default mode is dry-run. Real removal requires both --apply and --yes.
EOF
}

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

env_unquote() {
  local value="$1"
  case "$value" in
    \"*\") value="${value:1:${#value}-2}"; value="${value//\\\"/\"}"; value="${value//\\\\/\\}" ;;
    \'*\') value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

load_config_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="$(env_unquote "$value")"
    case "$key" in
      XUI_DOMAIN|REALITY_DEST|NH_PROXY_DOMAIN|PROXY_DOMAIN|NAIVE_DOMAIN)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$file"
}

is_safe_domain_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ && "$1" != "." && "$1" != ".." ]]
}

run() {
  if [[ "$APPLY" == "1" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  else
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  fi
}

run_shell() {
  local command="$1"
  if [[ "$APPLY" == "1" ]]; then
    printf '+ bash -c %q\n' "$command"
    bash -c "$command"
  else
    printf '[dry-run] bash -c %q\n' "$command"
  fi
}

protected_path() {
  local path="$1"
  case "$path" in
    /etc/letsencrypt|/etc/letsencrypt/live|/etc/letsencrypt/live/*|/etc/letsencrypt/archive|/etc/letsencrypt/archive/*|/etc/letsencrypt/renewal|/etc/letsencrypt/renewal/*|/etc/letsencrypt/accounts|/etc/letsencrypt/accounts/*|/etc/letsencrypt/keys|/etc/letsencrypt/keys/*|/etc/letsencrypt/csr|/etc/letsencrypt/csr/*|/root/cert|/root/cert/*|/var/lib/caddy|/var/lib/caddy/*|/root/.local/share/caddy|/root/.local/share/caddy/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

backup_path() {
  local path="$1" dest
  [[ -e "$path" || -L "$path" ]] || return 0
  protected_path "$path" && return 0
  dest="$BACKUP_DIR$path"
  if [[ "$APPLY" == "1" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$path" "$dest"
  else
    printf '[dry-run] backup %q -> %q\n' "$path" "$dest"
  fi
}

remove_path() {
  local path="$1"
  [[ -n "$path" && "$path" == /* ]] || die "Refusing unsafe path: $path"
  if protected_path "$path"; then
    warn "Preserved certificate path: $path"
    return 0
  fi
  [[ -e "$path" || -L "$path" ]] || return 0
  backup_path "$path"
  run rm -rf -- "$path"
}

stop_disable_service() {
  local svc="$1"
  command_exists systemctl || return 0
  run systemctl stop "$svc" || true
  run systemctl disable "$svc" || true
}

remove_unit() {
  local unit="$1"
  remove_path "/etc/systemd/system/$unit"
}

remove_nginx_site_name() {
  local name="$1"
  [[ -n "$name" ]] || return 0
  is_safe_domain_name "$name" || { warn "Skip unsafe nginx site name: $name"; return 0; }
  remove_path "/etc/nginx/sites-enabled/$name"
  remove_path "/etc/nginx/sites-available/$name"
}

clean_crontab() {
  command_exists crontab || return 0
  run_shell "tmp=\$(mktemp); crontab -l 2>/dev/null | grep -vE '(^|[[:space:]/])(x-ui|sub2sing-box|cloudflareips)([[:space:]]|\$)' > \"\$tmp\" || true; crontab \"\$tmp\"; rm -f \"\$tmp\""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --remove-warp) REMOVE_WARP=1; shift ;;
    --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
if [[ "$APPLY" == "1" && "$ASSUME_YES" != "1" ]]; then
  die "Real removal requires --apply --yes"
fi

load_config_env "$SCRIPT_DIR/config.env"
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-${NAIVE_DOMAIN:-}}}"

BACKUP_DIR="${BACKUP_ROOT%/}/uninstall-$(date '+%Y-%m-%d-%H-%M-%S')"

cat <<EOF
Unified Proxy Manager uninstall
===============================
Mode:        $([[ "$APPLY" == "1" ]] && printf apply || printf dry-run)
Backup:      $BACKUP_DIR
Remove WARP: $REMOVE_WARP

Certificates preserved:
  /etc/letsencrypt live/archive/renewal/accounts/keys/csr
  /root/cert
  /var/lib/caddy
  /root/.local/share/caddy
EOF

if [[ "$APPLY" == "1" ]]; then
  mkdir -p "$BACKUP_DIR"
fi

info "Stopping services"
for svc in x-ui panel-naive-mieru caddy-naive mita panel-naive-hy2 caddy-nh hysteria-server caddy-cert-watcher.path caddy-cert-watcher.service; do
  stop_disable_service "$svc"
done
if command_exists pm2; then
  run pm2 delete panel-naive-mieru || true
  run pm2 save || true
fi
if [[ "$REMOVE_WARP" == "1" ]]; then
  stop_disable_service warp-svc
fi

info "Backing up and removing service units"
for unit in \
  x-ui.service \
  panel-naive-mieru.service \
  caddy-naive.service \
  mita.service \
  panel-naive-hy2.service \
  caddy-nh.service \
  hysteria-server.service \
  caddy-cert-watcher.path \
  caddy-cert-watcher.service; do
  remove_unit "$unit"
done

info "Removing stack files"
for path in \
  /etc/x-ui \
  /usr/local/x-ui \
  /usr/bin/x-ui \
  /opt/panel-naive-mieru \
  /etc/caddy-naive \
  /etc/rixxx-panel \
  /var/lib/rixxx-panel \
  /usr/local/bin/caddy-naive \
  /opt/panel-naive-hy2 \
  /etc/caddy-nh \
  /etc/hysteria \
  /etc/nh-panel \
  /usr/bin/caddy-nh \
  /etc/letsencrypt/renewal-hooks/deploy/nh-unified-reload.sh; do
  remove_path "$path"
done

info "Removing stack nginx files"
for path in \
  /etc/nginx/stream-enabled/stream.conf \
  /etc/nginx/stream-enabled/warp-8443.conf \
  /etc/nginx/sites-enabled/80.conf \
  /etc/nginx/sites-available/80.conf \
  /etc/nginx/sites-enabled/nh-acme \
  /etc/nginx/sites-available/nh-acme \
  /etc/nginx/sites-enabled/panel-naive-hy2 \
  /etc/nginx/sites-available/panel-naive-hy2 \
  /etc/nginx/sites-enabled/panel-naive-mieru \
  /etc/nginx/sites-available/panel-naive-mieru \
  /etc/nginx/snippets/nh-subscriptions.conf \
  /etc/nginx/conf.d/nh-subscriptions.conf; do
  remove_path "$path"
done
if [[ -d /etc/nginx/stream-enabled ]]; then
  for path in /etc/nginx/stream-enabled/warp-*.conf; do
    [[ -e "$path" ]] || continue
    remove_path "$path"
  done
fi

remove_nginx_site_name "$XUI_DOMAIN"
remove_nginx_site_name "$REALITY_DEST"
remove_nginx_site_name "$NH_PROXY_DOMAIN"
remove_nginx_site_name "$NAIVE_DOMAIN"

info "Cleaning crontab entries owned by stack"
clean_crontab

if [[ "$REMOVE_WARP" == "1" ]]; then
  info "Removing Cloudflare WARP package and config"
  remove_path /etc/apt/sources.list.d/cloudflare-client.list
  remove_path /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  if command_exists apt-get; then
    run apt-get purge -y cloudflare-warp || true
    run apt-get autoremove -y || true
  fi
fi

if command_exists systemctl; then
  run systemctl daemon-reload || true
fi
if command_exists nginx && [[ -d /etc/nginx ]]; then
  if [[ "$APPLY" == "1" ]]; then
    nginx -t && systemctl reload nginx || warn "nginx reload skipped/failed; inspect nginx config manually"
  else
    printf '[dry-run] nginx -t && systemctl reload nginx\n'
  fi
fi

ok "Uninstall completed ($([[ "$APPLY" == "1" ]] && printf applied || printf dry-run))"
ok "Certificate stores were preserved"
