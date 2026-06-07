#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${UPM_PROJECT_DIR:-$SCRIPT_DIR}"
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/fake-site.sh"

ROOT_DIR="/var/www/html"
PATCH_NGINX=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage:
  sudo bash install-fake-site.sh --yes
  sudo bash install-fake-site.sh --patch-nginx --yes

Options:
  --root DIR       web root, default: $ROOT_DIR
  --patch-nginx    update common x-ui nginx fallbacks to serve the fake error page
  --yes            apply changes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT_DIR="${2:-}"; shift 2 ;;
    --patch-nginx) PATCH_NGINX=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { printf 'ERROR: Run as root\n' >&2; exit 1; }
[[ "$ASSUME_YES" == "1" ]] || { printf 'ERROR: Add --yes after reading what this script changes\n' >&2; exit 1; }

upm_install_fake_site "$ROOT_DIR"
printf 'OK: Fake error site installed in %s\n' "$ROOT_DIR"

if [[ "$PATCH_NGINX" == "1" && -d /etc/nginx ]]; then
  backup_dir="/opt/unified-proxy-manager/backups/fake-site-nginx-$(date '+%Y-%m-%d-%H-%M-%S')"
  mkdir -p "$backup_dir/etc/nginx"
  cp -a /etc/nginx "$backup_dir/etc/" 2>/dev/null || true

  while IFS= read -r -d '' file; do
    sed -i \
      -e 's#error_page 400 401 402 403 500 501 502 503 504 =404 /404;#error_page 400 401 402 403 404 500 501 502 503 504 /internal-server-error.html;#g' \
      -e 's#error_page 400 401 402 403 500 501 502 503 504 /internal-server-error.html;#error_page 400 401 402 403 404 500 501 502 503 504 /internal-server-error.html;#g' \
      -e 's#location / { try_files \$uri \$uri/ =404; }#location / { try_files \$uri \$uri/ /internal-server-error.html; }#g' \
      "$file"
  done < <(find /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/snippets -type f -print0 2>/dev/null)

  if nginx -t; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    printf 'OK: nginx fallback patched and reloaded\n'
    printf 'Backup: %s\n' "$backup_dir"
  else
    printf 'ERROR: nginx validation failed after patch. Backup: %s\n' "$backup_dir" >&2
    exit 1
  fi
fi
