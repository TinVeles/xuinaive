#!/usr/bin/env bash

upm_script_dir() {
  local source_path="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  if [[ "$source_path" == /dev/fd/* || "$source_path" == /proc/* || ! -f "$source_path" ]]; then
    pwd
  else
    cd "$(dirname "$source_path")" && pwd
  fi
}

if ! declare -F command_exists >/dev/null 2>&1; then
  command_exists() { command -v "$1" >/dev/null 2>&1; }
fi

if ! declare -F info >/dev/null 2>&1; then
  info() { printf 'INFO: %s\n' "$*"; }
fi

if ! declare -F ok >/dev/null 2>&1; then
  ok() { printf 'OK: %s\n' "$*"; }
fi

if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf 'WARN: %s\n' "$*"; }
fi

if ! declare -F err >/dev/null 2>&1; then
  err() { printf 'ERROR: %s\n' "$*" >&2; }
fi

if ! declare -F die >/dev/null 2>&1; then
  die() { err "$*"; exit 1; }
fi

upm_log_info() {
  if declare -F msg_inf >/dev/null 2>&1; then msg_inf "$@"; elif declare -F info >/dev/null 2>&1; then info "$@"; else printf 'INFO: %s\n' "$*"; fi
}

upm_log_ok() {
  if declare -F msg_ok >/dev/null 2>&1; then msg_ok "$@"; elif declare -F ok >/dev/null 2>&1; then ok "$@"; else printf 'OK: %s\n' "$*"; fi
}

upm_log_warn() {
  if declare -F warn >/dev/null 2>&1; then warn "$@"; elif declare -F msg_inf >/dev/null 2>&1; then msg_inf "WARN: $*"; else printf 'WARN: %s\n' "$*"; fi
}

upm_die() {
  if declare -F die >/dev/null 2>&1; then die "$@"; elif declare -F msg_err >/dev/null 2>&1; then msg_err "$@"; exit 1; else printf 'ERROR: %s\n' "$*" >&2; exit 1; fi
}

sql_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

sql_int() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || { printf '0'; return 1; }
  printf '%s' "$value"
}

upm_redact() {
  local value="${1:-}"
  local mode="${UPM_REDACT_SECRETS:-0}"
  [[ "$mode" == "1" ]] || { printf '%s' "$value"; return 0; }
  local len="${#value}"
  if (( len <= 4 )); then
    printf '****'
  elif (( len <= 8 )); then
    printf '%s****' "${value:0:1}"
  else
    printf '%s****%s' "${value:0:2}" "${value: -2}"
  fi
}

uri_encode() {
  local value="${1:-}"
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1] || ""))' "$value"
}

naive_uri() {
  local username="$1" password="$2" domain="$3" name="${4:-}"
  local user_enc pass_enc name_part=""
  user_enc="$(uri_encode "$username")"
  pass_enc="$(uri_encode "$password")"
  [[ -n "$name" ]] && name_part="#$(uri_encode "$name")"
  printf 'naive+https://%s:%s@%s:443%s\n' "$user_enc" "$pass_enc" "$domain" "$name_part"
}

upm_sqlite_setting_set() {
  local db="$1" key="$2" value="$3" changes
  changes="$(sqlite3 "$db" "UPDATE settings SET value=$(sql_quote "$value") WHERE key=$(sql_quote "$key"); SELECT changes();" | tail -n 1)"
  [[ "$changes" =~ ^[0-9]+$ ]] || return 1
  if [[ "$changes" == "0" ]]; then
    sqlite3 "$db" "INSERT INTO settings (key, value) VALUES ($(sql_quote "$key"), $(sql_quote "$value"));"
  fi
}

confirm_destructive() {
  local context="${1:-destructive operation}"
  local allow_flag="${UPM_ALLOW_DESTROY_EXISTING:-0}"
  if [[ "$allow_flag" == "1" ]]; then
    upm_log_warn "Proceeding with $context (UPM_ALLOW_DESTROY_EXISTING=1)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    upm_die "$context requires --allow-destroy-existing or interactive confirmation"
  fi
  printf '\n!!! %s WILL DESTROY EXISTING STATE.\n' "$context" >&2
  printf '!!! Pass --allow-destroy-existing to skip this prompt next time.\n' >&2
  printf 'Type DESTROY to proceed: ' >&2
  local reply
  IFS= read -r reply || reply=""
  [[ "$reply" == "DESTROY" ]] || upm_die "$context cancelled"
}

upm_config_set_many() {
  local file="$1" tmp pattern key value value_escaped
  shift
  tmp="$(mktemp)"
  pattern="^($(printf '%s\n' "$@" | awk 'NR % 2 == 1' | sed 's/[.[\*^$()+?{}|]/\\&/g' | paste -sd '|' -))="
  if [[ -f "$file" ]]; then
    grep -vE "$pattern" "$file" > "$tmp" || true
  fi
  while [[ $# -gt 0 ]]; do
    key="$1"
    value="$2"
    shift 2
    value_escaped="${value//\\/\\\\}"
    value_escaped="${value_escaped//\"/\\\"}"
    printf '%s="%s"\n' "$key" "$value_escaped" >> "$tmp"
  done
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

nginx_config_contains() {
  local needle="$1"
  nginx -T 2>/dev/null | grep -Fq "$needle"
}

upm_install_secret() {
  local mode="$1" dest="$2" tmp
  shift 2
  tmp="$(mktemp)"
  chmod "$mode" "$tmp" 2>/dev/null || true
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" > "$tmp"
  else
    cat > "$tmp"
  fi
  install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

upm_assert_xui_creds_rotated() {
  local db="${1:-/etc/x-ui/x-ui.db}"
  command_exists sqlite3 || { upm_log_warn "sqlite3 missing; cannot verify x-ui creds rotation"; return 0; }
  [[ -f "$db" ]] || { upm_log_warn "x-ui DB not found at $db; cannot verify creds rotation"; return 0; }
  local username port
  username="$(sqlite3 -readonly "$db" "SELECT value FROM settings WHERE key='username';" 2>/dev/null || printf '')"
  port="$(sqlite3 -readonly "$db" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || printf '')"
  if [[ "$username" == "asdfasdf" || "$port" == "2096" ]]; then
    upm_die "x-ui still has upstream default credentials (username=$username port=$port). Installation aborted before rotation. Re-run installer or reset manually via 'x-ui setting -username NEW -password NEW -port PORT -webBasePath PATH'."
  fi
}


nginx_enable_stream_include() {
  local main_conf="/etc/nginx/nginx.conf" backup
  [[ -f "$main_conf" ]] || { upm_log_warn "$main_conf not found; stream include was not configured"; return 1; }
  nginx_config_contains "/etc/nginx/stream-enabled/*.conf" && return 0
  backup="$(mktemp)"
  cp -a "$main_conf" "$backup"
  printf '\nstream { include /etc/nginx/stream-enabled/*.conf; }\n' >> "$main_conf"
  if ! nginx -t >/dev/null 2>&1; then
    cp -a "$backup" "$main_conf"
    rm -f "$backup"
    upm_log_warn "Could not add nginx stream include; restored $main_conf"
    return 1
  fi
  rm -f "$backup"
}
