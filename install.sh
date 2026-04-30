#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
RUN_FROM_STREAM=0
if [[ "$SOURCE_PATH" == /dev/fd/* || "$SOURCE_PATH" == /proc/* || ! -f "$SOURCE_PATH" ]]; then
  SCRIPT_DIR="$(pwd)"
  RUN_FROM_STREAM=1
else
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
fi

MODE=""
XUI_DOMAIN="${XUI_DOMAIN:-}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
REALITY_DEST="${REALITY_DEST:-}"
NAIVE_EMAIL="${NAIVE_EMAIL:-}"
PROJECT_DIR="${UPM_PROJECT_DIR:-$SCRIPT_DIR}"
XUI_UPSTREAM="${XUI_UPSTREAM:-upstreams/x-ui-pro/x-ui-pro.sh}"
NAIVE_UPSTREAM="${NAIVE_UPSTREAM:-upstreams/naiveproxy-instant-install-by-Ilya_Rublev/install.sh}"
XUI_REPO="${XUI_REPO:-https://github.com/mozaroc/x-ui-pro.git}"
NAIVE_REPO="${NAIVE_REPO:-https://github.com/Rublev13/naiveproxy-instant-install-by-Ilya_Rublev.git}"
AUTO_FETCH_UPSTREAMS="${AUTO_FETCH_UPSTREAMS:-ask}"
FETCH_ONLY=0
REAL_INSTALL=0
ASSUME_YES=0
DRY_RUN=1

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() { printf '%s\n' "${BLUE}INFO:${NC} $*"; }
ok() { printf '%s\n' "${GREEN}OK:${NC} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN:${NC} $*"; }
err() { printf '%s\n' "${RED}ERROR:${NC} $*" >&2; }
die() { err "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  ./install.sh
  ./install.sh --mode xui --xui-domain x.example.com --reality-dest r.example.com [--dry-run]
  ./install.sh --mode naive --naive-domain n.example.com [--dry-run]
  ./install.sh --mode both --xui-domain x.example.com --naive-domain n.example.com --reality-dest r.example.com [--dry-run]
  ./install.sh --mode both --xui-domain x.example.com --naive-domain n.example.com --reality-dest r.example.com --naive-email admin@example.com --install --yes
  ./install.sh --fetch-upstreams
  bash <(wget -qO- RAW_INSTALL_URL)

Default mode is dry-run only. Real install requires --install --yes.
When values are omitted in an interactive terminal, the script asks for them.
When run from a URL, relative paths are resolved from the current directory or --project-dir.
If upstream projects are missing, the script can fetch them into upstreams/.
EOF
}

require_interactive() {
  [[ -t 0 ]] || die "Missing required arguments and stdin is not interactive. Run ./install.sh in a terminal or pass CLI flags."
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local current_value="${3:-}"
  local input=""

  require_interactive
  while [[ -z "$current_value" ]]; do
    read -r -p "$prompt: " input
    current_value="$(printf '%s' "$input" | tr -d '[:space:]')"
  done
  printf -v "$var_name" '%s' "$current_value"
}

prompt_mode() {
  local input=""
  require_interactive
  while [[ -z "$MODE" ]]; do
    echo "Choose install planning mode:"
    echo "  1) xui   - x-ui-pro / 3x-ui only"
    echo "  2) naive - NaiveProxy / Caddy only"
    echo "  3) both  - analyze both components"
    read -r -p "Mode [xui/naive/both or 1/2/3]: " input
    case "$input" in
      1|xui) MODE="xui" ;;
      2|naive) MODE="naive" ;;
      3|both) MODE="both" ;;
      *) warn "Please enter xui, naive, both, 1, 2, or 3." ;;
    esac
  done
}

collect_interactive_inputs() {
  [[ -n "$MODE" ]] || prompt_mode

  case "$MODE" in
    xui)
      prompt_value XUI_DOMAIN "Enter x-ui domain, for example x.example.com" "$XUI_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example r.example.com" "$REALITY_DEST"
      ;;
    naive)
      prompt_value NAIVE_DOMAIN "Enter NaiveProxy domain, for example n.example.com" "$NAIVE_DOMAIN"
      prompt_value NAIVE_EMAIL "Enter email for future Caddy/Let's Encrypt planning" "$NAIVE_EMAIL"
      ;;
    both)
      prompt_value XUI_DOMAIN "Enter x-ui domain, for example x.example.com" "$XUI_DOMAIN"
      prompt_value NAIVE_DOMAIN "Enter NaiveProxy domain, for example n.example.com" "$NAIVE_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example r.example.com" "$REALITY_DEST"
      prompt_value NAIVE_EMAIL "Enter email for future Caddy/Let's Encrypt planning" "$NAIVE_EMAIL"
      ;;
    *) die "--mode must be xui, naive, or both" ;;
  esac
}

collect_real_install_inputs() {
  if [[ "$REAL_INSTALL" != "1" ]]; then
    return 0
  fi
  [[ "$MODE" == "both" ]] || die "Real unified install currently supports --mode both only"
  prompt_value XUI_DOMAIN "Enter x-ui domain, for example zaiki.example.com" "$XUI_DOMAIN"
  prompt_value NAIVE_DOMAIN "Enter NaiveProxy domain, for example sub.example.com" "$NAIVE_DOMAIN"
  prompt_value REALITY_DEST "Enter REALITY destination domain, for example example.com" "$REALITY_DEST"
  prompt_value NAIVE_EMAIL "Enter email for Caddy/Let's Encrypt" "$NAIVE_EMAIL"
}

load_config() {
  local config_file="$PROJECT_DIR/config.env"
  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi
}

preparse_project_dir() {
  local args=("$@")
  local i=0
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      --project-dir)
        (( i + 1 < ${#args[@]} )) || die "--project-dir requires a value"
        PROJECT_DIR="${args[$((i + 1))]}"
        ;;
    esac
    ((i++))
  done
  PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || printf '%s' "$PROJECT_DIR")"
}

resolve_project_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$PROJECT_DIR/$path" ;;
  esac
}

upstream_paths() {
  XUI_UPSTREAM_PATH="$(resolve_project_path "$XUI_UPSTREAM")"
  NAIVE_UPSTREAM_PATH="$(resolve_project_path "$NAIVE_UPSTREAM")"
}

clone_or_update_upstream() {
  local repo_url="$1"
  local target_dir="$2"
  local name="$3"

  command_exists git || die "git is required to fetch upstream projects"
  mkdir -p "$(dirname "$target_dir")"

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

fetch_upstreams() {
  local upstreams_dir xui_dir naive_dir
  upstreams_dir="$PROJECT_DIR/upstreams"
  xui_dir="$upstreams_dir/x-ui-pro"
  naive_dir="$upstreams_dir/naiveproxy-instant-install-by-Ilya_Rublev"

  clone_or_update_upstream "$XUI_REPO" "$xui_dir" "x-ui-pro"
  clone_or_update_upstream "$NAIVE_REPO" "$naive_dir" "NaiveProxy installer"
}

maybe_fetch_upstreams() {
  upstream_paths
  [[ -f "$XUI_UPSTREAM_PATH" && -f "$NAIVE_UPSTREAM_PATH" ]] && return 0

  case "$AUTO_FETCH_UPSTREAMS" in
    yes)
      fetch_upstreams
      ;;
    no)
      return 0
      ;;
    ask)
      if [[ -t 0 ]]; then
        local answer=""
        warn "Upstream projects are missing in $PROJECT_DIR/upstreams."
        read -r -p "Fetch upstream projects now? [y/N]: " answer
        answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        case "$answer" in
          y|yes|д|да) fetch_upstreams ;;
          *) warn "Skipping upstream fetch." ;;
        esac
      fi
      ;;
    *) die "AUTO_FETCH_UPSTREAMS must be ask, yes, or no" ;;
  esac
}

public_ipv4() {
  local ip=""
  if command_exists ip; then
    ip="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$ip" ]] && command_exists curl; then
    ip="$(curl -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  printf '%s\n' "$ip"
}

domain_a_records() {
  local domain="$1"
  if command_exists getent; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  elif command_exists dig; then
    dig +short A "$domain" 2>/dev/null | sort -u
  else
    return 1
  fi
}

port_details() {
  local port="$1"
  if command_exists ss; then
    ss -H -ltnup "sport = :$port" 2>/dev/null || true
  elif command_exists lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  else
    return 0
  fi
}

show_port_report() {
  local port details
  for port in 80 443 2053 8443 9443; do
    details="$(port_details "$port")"
    if [[ -n "$details" ]]; then
      warn "Port $port is busy:"
      printf '%s\n' "$details"
    else
      ok "Port $port is free or listener was not detected"
    fi
  done
}

service_line() {
  local svc="$1"
  if ! command_exists systemctl; then
    printf '%-8s systemctl not available\n' "$svc"
    return 0
  fi
  local active enabled
  active="$(systemctl is-active "$svc" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
  printf '%-8s active=%-10s enabled=%s\n' "$svc" "${active:-unknown}" "${enabled:-unknown}"
}

show_service_report() {
  service_line x-ui
  service_line nginx
  service_line caddy
  service_line ufw
}

check_os() {
  if [[ ! -r /etc/os-release ]]; then
    warn "/etc/os-release not found; OS support cannot be verified here"
    return 0
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12) ok "Supported OS: ${PRETTY_NAME:-$ID $VERSION_ID}" ;;
    *) warn "Unsupported or untested OS: ${PRETTY_NAME:-unknown}. Target support: Ubuntu 22.04/24.04 or Debian 12." ;;
  esac
}

check_required_commands() {
  local cmd
  for cmd in curl wget git systemctl; do
    if command_exists "$cmd"; then
      ok "Command available: $cmd"
    else
      warn "Command missing: $cmd"
    fi
  done
}

check_upstream_files() {
  local xui_path naive_path
  upstream_paths
  xui_path="$XUI_UPSTREAM_PATH"
  naive_path="$NAIVE_UPSTREAM_PATH"
  if [[ -f "$xui_path" ]]; then
    ok "x-ui-pro upstream found: $XUI_UPSTREAM"
  else
    warn "x-ui-pro upstream not found: $XUI_UPSTREAM"
    warn "Run ./prepare-upstreams.sh or rerun ./install.sh --fetch-upstreams to fetch it."
  fi
  if [[ -f "$naive_path" ]]; then
    ok "NaiveProxy upstream found: $NAIVE_UPSTREAM"
  else
    warn "NaiveProxy upstream not found: $NAIVE_UPSTREAM"
    warn "Run ./prepare-upstreams.sh or rerun ./install.sh --fetch-upstreams to fetch it."
  fi
}

check_vendored_components() {
  local missing=0
  local path
  for path in \
    "$PROJECT_DIR/install-unified.sh" \
    "$PROJECT_DIR/components/x-ui-pro/x-ui-pro.sh" \
    "$PROJECT_DIR/components/x-ui-pro/apply-naive-sni-route.sh" \
    "$PROJECT_DIR/components/naiveproxy/install.sh" \
    "$PROJECT_DIR/components/naiveproxy/install-unified-backend.sh"; do
    if [[ -f "$path" ]]; then
      ok "Vendored component found: ${path#$PROJECT_DIR/}"
    else
      warn "Vendored component missing: ${path#$PROJECT_DIR/}"
      missing=1
    fi
  done
  [[ "$missing" == "0" ]] || die "Repository is incomplete. Run git pull or clone the latest TinVeles/xuinaive."
}

check_domain() {
  local domain="$1"
  local label="$2"
  [[ -n "$domain" ]] || { warn "$label domain is not set"; return 0; }

  local ip records
  ip="$(public_ipv4)"
  records="$(domain_a_records "$domain" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"

  if [[ -z "$records" ]]; then
    warn "$label domain $domain has no detected A records"
  elif [[ -n "$ip" ]] && grep -qw "$ip" <<<"$records"; then
    ok "$label domain $domain resolves to this server IPv4 ($ip)"
  elif [[ -n "$ip" ]]; then
    warn "$label domain $domain resolves to [$records], server IPv4 appears to be $ip"
  else
    warn "$label domain $domain resolves to [$records], but server IPv4 could not be detected"
  fi
}

validate_required_args() {
  case "$MODE" in
    xui)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for --mode xui"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for --mode xui"
      ;;
    naive)
      [[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required for --mode naive"
      ;;
    both)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for --mode both"
      [[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required for --mode both"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for --mode both"
      ;;
    *) die "--mode must be xui, naive, or both" ;;
  esac
}

validate_real_install_args() {
  [[ "$REAL_INSTALL" == "1" ]] || return 0
  [[ "$MODE" == "both" ]] || die "Real unified install currently supports --mode both only"
  [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for real install"
  [[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required for real install"
  [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for real install"
  [[ -n "$NAIVE_EMAIL" ]] || die "--naive-email is required for real install"
  [[ "$ASSUME_YES" == "1" ]] || die "Real install requires --yes"
}

print_plan() {
  if [[ "$REAL_INSTALL" == "1" ]]; then
    cat <<EOF

Real unified installation plan
------------------------------
Mode:           $MODE
Project dir:    $PROJECT_DIR
x-ui domain:    ${XUI_DOMAIN:-not set}
Naive domain:   ${NAIVE_DOMAIN:-not set}
REALITY dest:   ${REALITY_DEST:-not set}
Naive email:    ${NAIVE_EMAIL:-not set}

Changes will be made because --install --yes was provided.
Packages may be installed.
Services may be started/stopped/restarted.
Vendored component scripts will be executed.
EOF
  else
    cat <<EOF

Dry-run installation plan
-------------------------
Mode:           $MODE
Project dir:    $PROJECT_DIR
Run from URL:   $RUN_FROM_STREAM
Upstream fetch: $AUTO_FETCH_UPSTREAMS
x-ui domain:    ${XUI_DOMAIN:-not set}
Naive domain:   ${NAIVE_DOMAIN:-not set}
REALITY dest:   ${REALITY_DEST:-not set}
Naive email:    ${NAIVE_EMAIL:-not set}

No changes will be made.
No packages will be installed.
No services will be started/stopped.
No upstream scripts will be executed.
EOF
  fi

  case "$MODE" in
    xui)
      cat <<'EOF'

Planned x-ui-pro actions for a future real installer:
- verify DNS and free public ports 80/443;
- warn that upstream x-ui-pro.sh is destructive to existing x-ui/nginx configs;
- backup /etc/nginx, /etc/x-ui, /usr/local/x-ui before any real run;
- call upstream x-ui-pro.sh only after explicit confirmation.
EOF
      ;;
    naive)
      cat <<'EOF'

Planned NaiveProxy actions for a future real installer:
- verify DNS and free public ports 80/443;
- require NAIVE_EMAIL for Caddy TLS;
- backup /etc/caddy and caddy.service before any real run;
- feed domain/email to upstream install.sh only after explicit confirmation.
EOF
      ;;
    both)
      if [[ "$REAL_INSTALL" == "1" ]]; then
        cat <<'EOF'

Unified both-mode layout:
- nginx/x-ui-pro owns public 443.
- NaiveProxy/Caddy runs as caddy-naive on 127.0.0.1:9444.
- nginx stream routes the NaiveProxy domain by SNI to 127.0.0.1:9444.
EOF
      else
        cat <<'EOF'

Both-mode safety decision:
- x-ui-pro/nginx and NaiveProxy/Caddy both want public 443.
- This dry-run version will not install both stacks on one VPS.
- Safe options are separate VPS instances, or a manually reviewed single SNI router on 443 with loopback backends.
EOF
      fi
      ;;
  esac
}

run_real_install() {
  local installer="$PROJECT_DIR/install-unified.sh"
  [[ "$REAL_INSTALL" == "1" ]] || return 0
  [[ -f "$installer" ]] || die "Real installer not found: $installer. Pull latest repository version."

  cat <<EOF

Real install requested
----------------------
Installer:      $installer
Mode:           $MODE
x-ui domain:    $XUI_DOMAIN
Naive domain:   $NAIVE_DOMAIN
REALITY dest:   $REALITY_DEST
Naive email:    $NAIVE_EMAIL

This will run the vendored x-ui-pro installer and write system configs.
EOF

  bash "$installer" --mode both \
    --xui-domain "$XUI_DOMAIN" \
    --naive-domain "$NAIVE_DOMAIN" \
    --reality-dest "$REALITY_DEST" \
    --naive-email "$NAIVE_EMAIL" \
    --yes
}

preparse_project_dir "$@"
load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --xui-domain) XUI_DOMAIN="${2:-}"; shift 2 ;;
    --naive-domain) NAIVE_DOMAIN="${2:-}"; shift 2 ;;
    --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
    --naive-email) NAIVE_EMAIL="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --fetch-upstreams) AUTO_FETCH_UPSTREAMS=yes; FETCH_ONLY=1; shift ;;
    --no-fetch-upstreams) AUTO_FETCH_UPSTREAMS=no; shift ;;
    --install) REAL_INSTALL=1; DRY_RUN=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "$FETCH_ONLY" == "1" && -z "$MODE" && -z "$XUI_DOMAIN" && -z "$NAIVE_DOMAIN" && -z "$REALITY_DEST" ]]; then
  info "Fetching upstream projects only"
  fetch_upstreams
  cat <<EOF

Upstream fetch complete.
Next step:
  sudo ./install.sh
EOF
  exit 0
fi

if [[ "$REAL_INSTALL" == "1" ]]; then
  [[ -n "$MODE" ]] || MODE="both"
  collect_real_install_inputs
else
  collect_interactive_inputs
fi
case "$MODE" in xui|naive|both) ;; *) die "--mode must be xui, naive, or both" ;; esac

validate_required_args
validate_real_install_args

if [[ "$REAL_INSTALL" == "1" ]]; then
  info "Running preflight before real unified install"
else
  info "Running safe dry-run analysis only"
fi
[[ "${EUID:-$(id -u)}" -eq 0 ]] || warn "Not running as root; port/process details may be incomplete"
check_os
check_required_commands
if [[ "$REAL_INSTALL" == "1" ]]; then
  check_vendored_components
else
  maybe_fetch_upstreams
  check_upstream_files
fi

echo
echo "Service status:"
show_service_report

echo
echo "Port status:"
show_port_report

echo
echo "DNS status:"
case "$MODE" in
  xui)
    check_domain "$XUI_DOMAIN" "x-ui"
    check_domain "$REALITY_DEST" "REALITY destination"
    ;;
  naive)
    check_domain "$NAIVE_DOMAIN" "NaiveProxy"
    ;;
  both)
    check_domain "$XUI_DOMAIN" "x-ui"
    check_domain "$NAIVE_DOMAIN" "NaiveProxy"
    check_domain "$REALITY_DEST" "REALITY destination"
    ;;
esac

print_plan
run_real_install
