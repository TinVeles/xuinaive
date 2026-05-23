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
  sudo bash update-subscriptions.sh --count 15 --prefix auto --yes

Refreshes only subscription files:
  - pulls current x-ui subscription for each generated subId;
  - appends existing NaiveProxy and Hysteria2 links;
  - writes auto-XX.txt, combined.txt, v2rayn*.txt files.

Does not edit x-ui clients, NHM users, inbounds, routing, or passwords.
EOF
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done

exec bash "$SCRIPT_DIR/generate-profiles.sh" --combined-only "${args[@]}"
