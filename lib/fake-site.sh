#!/usr/bin/env bash

upm_install_fake_site() {
  local root_dir="${1:-/var/www/html}"
  local project_dir="${UPM_PROJECT_DIR:-${PROJECT_DIR:-}}"
  local template=""
  local template_dir=""
  local target

  if [[ -n "$project_dir" && -f "$project_dir/fake-site/internal-server-error.html" ]]; then
    template_dir="$project_dir/fake-site"
    template="$template_dir/internal-server-error.html"
  elif [[ -n "${UPM_ROOT_DIR:-}" && -f "$UPM_ROOT_DIR/fake-site/internal-server-error.html" ]]; then
    template_dir="$UPM_ROOT_DIR/fake-site"
    template="$template_dir/internal-server-error.html"
  else
    return 0
  fi

  mkdir -p "$root_dir"
  for target in index.html internal-server-error.html 404 404.html 50x.html; do
    install -m 0644 "$template" "$root_dir/$target"
  done
  for target in internal-server-error.css internal-server-error.js; do
    [[ -f "$template_dir/$target" ]] || continue
    install -m 0644 "$template_dir/$target" "$root_dir/$target"
  done
}
