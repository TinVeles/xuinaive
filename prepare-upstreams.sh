#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAMS_DIR="$SCRIPT_DIR/upstreams"

XUI_REPO="${XUI_REPO:-https://github.com/mozaroc/x-ui-pro.git}"
NAIVE_REPO="${NAIVE_REPO:-https://github.com/Rublev13/naiveproxy-instant-install-by-Ilya_Rublev.git}"

XUI_DIR="$UPSTREAMS_DIR/x-ui-pro"
NAIVE_DIR="$UPSTREAMS_DIR/naiveproxy-instant-install-by-Ilya_Rublev"

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"

mkdir -p "$UPSTREAMS_DIR"

clone_or_update() {
  local repo_url="$1"
  local target_dir="$2"
  local name="$3"

  if [[ -d "$target_dir/.git" ]]; then
    info "$name already exists, fetching latest refs"
    git -C "$target_dir" fetch --all --prune
    ok "$name is present: $target_dir"
    return 0
  fi

  if [[ -e "$target_dir" ]]; then
    warn "$target_dir exists but is not a git clone. Leaving it unchanged."
    return 0
  fi

  info "Cloning $name from $repo_url"
  git clone "$repo_url" "$target_dir"
  ok "$name cloned: $target_dir"
}

clone_or_update "$XUI_REPO" "$XUI_DIR" "x-ui-pro"
clone_or_update "$NAIVE_REPO" "$NAIVE_DIR" "NaiveProxy installer"

cat <<EOF

Upstreams are ready:
  x-ui-pro:    $XUI_DIR
  NaiveProxy:  $NAIVE_DIR

Next safe check:
  cd "$SCRIPT_DIR"
  sudo ./install.sh
EOF

