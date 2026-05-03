#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_UPDATE="$SCRIPT_DIR/upstream/update.sh"

[[ -f "$UPSTREAM_UPDATE" ]] || {
  printf 'ERROR: Missing upstream updater: %s\n' "$UPSTREAM_UPDATE" >&2
  exit 1
}

exec bash "$UPSTREAM_UPDATE" "$@"
