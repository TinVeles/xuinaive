#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

usage() {
  cat <<'EOF'
Usage:
  sudo bash update-subscriptions.sh --yes

This legacy combined-subscription wrapper was removed.

Use RIXXX Panel for NaiveProxy/Mieru links.
Use 3x-ui or configure-xui-subscription.sh for x-ui subscription URLs.
EOF
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done

usage >&2
exit 1
