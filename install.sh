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
RIXXX_PROXY_DOMAIN="${RIXXX_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
RIXXX_PROXY_EMAIL="${RIXXX_PROXY_EMAIL:-${PROXY_EMAIL:-}}"
RIXXX_STACK="${RIXXX_STACK:-both}"
RIXXX_ACCESS="${RIXXX_ACCESS:-nginx8080}"
RIXXX_PANEL_DOMAIN="${RIXXX_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
RIXXX_PANEL_EMAIL="${RIXXX_PANEL_EMAIL:-${PANEL_EMAIL:-}}"
RIXXX_SSH_ONLY="${RIXXX_SSH_ONLY:-0}"
RIXXX_MASQUERADE="${RIXXX_MASQUERADE:-local}"
RIXXX_MASQUERADE_URL="${RIXXX_MASQUERADE_URL:-}"
RIXXX_ALLOW_PORT_CONFLICT="${RIXXX_ALLOW_PORT_CONFLICT:-0}"
PROJECT_DIR="${UPM_PROJECT_DIR:-$SCRIPT_DIR}"
XUI_UPSTREAM="${XUI_UPSTREAM:-upstreams/x-ui-pro/x-ui-pro.sh}"
RIXXX_UPSTREAM="${RIXXX_UPSTREAM:-upstreams/Panel---Naive-Hy2---by---RIXXX/install.sh}"
XUI_REPO="${XUI_REPO:-https://github.com/mozaroc/x-ui-pro.git}"
RIXXX_REPO="${RIXXX_REPO:-https://github.com/cwash797-cmd/Panel---Naive-Hy2---by---RIXXX.git}"
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

info "xuinaive installer starting"

usage() {
  cat <<'EOF'
Usage:
  ./install.sh
  ./install.sh --mode xui --xui-domain x.example.com --reality-dest r.example.com [--dry-run]
  ./install.sh --mode naive --naive-domain n.example.com [--dry-run]
  ./install.sh --mode all --xui-domain x.example.com --rixxx-domain n.example.com --reality-dest r.example.com --rixxx-email admin@example.com --install --yes
  ./install.sh --mode rixxx --domain vpn.example.com --proxy-email admin@example.com --install --yes
  ./install.sh --fetch-upstreams
  bash <(wget -qO- RAW_INSTALL_URL)

Default mode is dry-run only. Real install requires --install --yes.
When values are omitted in an interactive terminal, the script asks for them.
When run from a URL, relative paths are resolved from the current directory or --project-dir.
If upstream projects are missing, the script can fetch them into upstreams/.
Mode all installs 3x-ui + RIXXX Panel + NaiveProxy + Hysteria2 on one VPS.
Mode rixxx installs only the standalone RIXXX NaiveProxy + Hysteria2 web panel.
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
    echo "  3) all   - 3x-ui + RIXXX Panel + NaiveProxy + Hysteria2"
    echo "  4) both  - legacy x-ui + NaiveProxy plan"
    echo "  5) rixxx - RIXXX NaiveProxy + Hysteria2 web panel only"
    read -r -p "Mode [xui/naive/all/both/rixxx or 1/2/3/4/5]: " input
    case "$input" in
      1|xui) MODE="xui" ;;
      2|naive) MODE="naive" ;;
      3|all) MODE="all" ;;
      4|both) MODE="both" ;;
      5|rixxx) MODE="rixxx" ;;
      *) warn "Please enter xui, naive, all, both, rixxx, 1, 2, 3, 4, or 5." ;;
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
    all)
      prompt_value XUI_DOMAIN "Enter x-ui domain, for example xui.example.com" "$XUI_DOMAIN"
      prompt_value RIXXX_PROXY_DOMAIN "Enter RIXXX/NaiveProxy domain, for example naive.example.com" "$RIXXX_PROXY_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example reality.example.com" "$REALITY_DEST"
      prompt_value RIXXX_PROXY_EMAIL "Enter email for Caddy/Let's Encrypt" "$RIXXX_PROXY_EMAIL"
      ;;
    rixxx)
      prompt_value RIXXX_PROXY_DOMAIN "Enter RIXXX proxy domain, for example vpn.example.com" "$RIXXX_PROXY_DOMAIN"
      prompt_value RIXXX_PROXY_EMAIL "Enter email for Let's Encrypt" "$RIXXX_PROXY_EMAIL"
      ;;
    *) die "--mode must be xui, naive, all, both, or rixxx" ;;
  esac
}

collect_real_install_inputs() {
  if [[ "$REAL_INSTALL" != "1" ]]; then
    return 0
  fi
  case "$MODE" in
    both)
      prompt_value XUI_DOMAIN "Enter x-ui domain, for example xui.example.com" "$XUI_DOMAIN"
      prompt_value NAIVE_DOMAIN "Enter NaiveProxy domain, for example naive.example.com" "$NAIVE_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example example.com" "$REALITY_DEST"
      prompt_value NAIVE_EMAIL "Enter email for Caddy/Let's Encrypt" "$NAIVE_EMAIL"
      ;;
    all)
      prompt_value XUI_DOMAIN "Enter x-ui domain, for example xui.example.com" "$XUI_DOMAIN"
      prompt_value RIXXX_PROXY_DOMAIN "Enter RIXXX/NaiveProxy domain, for example naive.example.com" "$RIXXX_PROXY_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example reality.example.com" "$REALITY_DEST"
      prompt_value RIXXX_PROXY_EMAIL "Enter email for Caddy/Let's Encrypt" "$RIXXX_PROXY_EMAIL"
      ;;
    rixxx)
      prompt_value RIXXX_PROXY_DOMAIN "Enter RIXXX proxy domain, for example vpn.example.com" "$RIXXX_PROXY_DOMAIN"
      prompt_value RIXXX_PROXY_EMAIL "Enter email for Let's Encrypt" "$RIXXX_PROXY_EMAIL"
      ;;
    *) die "Real install currently supports --mode all, --mode both, or --mode rixxx" ;;
  esac
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
    i=$((i + 1))
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
  RIXXX_UPSTREAM_PATH="$(resolve_project_path "$RIXXX_UPSTREAM")"
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
  local upstreams_dir xui_dir rixxx_dir
  upstreams_dir="$PROJECT_DIR/upstreams"
  xui_dir="$upstreams_dir/x-ui-pro"
  rixxx_dir="$upstreams_dir/Panel---Naive-Hy2---by---RIXXX"

  clone_or_update_upstream "$XUI_REPO" "$xui_dir" "x-ui-pro"
  clone_or_update_upstream "$RIXXX_REPO" "$rixxx_dir" "RIXXX panel"
}

maybe_fetch_upstreams() {
  upstream_paths
  [[ -f "$XUI_UPSTREAM_PATH" && -f "$RIXXX_UPSTREAM_PATH" ]] && return 0

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
  for port in 80 443 2053 3000 8080 8081 8443 9443 9445; do
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
  service_line caddy-rixxx
  service_line hysteria-server
  service_line panel-naive-hy2
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
  local xui_path rixxx_path
  upstream_paths
  xui_path="$XUI_UPSTREAM_PATH"
  rixxx_path="$RIXXX_UPSTREAM_PATH"
  if [[ -f "$xui_path" ]]; then
    ok "x-ui-pro upstream found: $XUI_UPSTREAM"
  else
    warn "x-ui-pro upstream not found: $XUI_UPSTREAM"
    warn "Run ./prepare-upstreams.sh or rerun ./install.sh --fetch-upstreams to fetch it."
  fi
  if [[ -f "$rixxx_path" ]]; then
    ok "RIXXX panel upstream found: $RIXXX_UPSTREAM"
  else
    warn "RIXXX panel upstream not found: $RIXXX_UPSTREAM"
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
    "$PROJECT_DIR/components/rixxx-panel/install.sh" \
    "$PROJECT_DIR/components/rixxx-panel/install-unified-backend.sh" \
    "$PROJECT_DIR/components/rixxx-panel/update.sh" \
    "$PROJECT_DIR/components/rixxx-panel/upstream/install.sh" \
    "$PROJECT_DIR/components/rixxx-panel/upstream/update.sh"; do
    if [[ -f "$path" ]]; then
      ok "Vendored component found: ${path#$PROJECT_DIR/}"
    else
      warn "Vendored component missing: ${path#$PROJECT_DIR/}"
      missing=1
    fi
  done
  [[ "$missing" == "0" ]] || die "Repository is incomplete. Pull or clone the latest project version."
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
    all)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for --mode all"
      [[ -n "$RIXXX_PROXY_DOMAIN" ]] || die "--rixxx-domain is required for --mode all"
      [[ -n "$RIXXX_PROXY_EMAIL" ]] || die "--rixxx-email is required for --mode all"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for --mode all"
      ;;
    rixxx)
      [[ -n "$RIXXX_PROXY_DOMAIN" ]] || die "--domain is required for --mode rixxx"
      [[ -n "$RIXXX_PROXY_EMAIL" ]] || die "--proxy-email is required for --mode rixxx"
      ;;
    *) die "--mode must be xui, naive, all, both, or rixxx" ;;
  esac
}

validate_real_install_args() {
  [[ "$REAL_INSTALL" == "1" ]] || return 0
  case "$MODE" in
    both)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for real install"
      [[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required for real install"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for real install"
      [[ -n "$NAIVE_EMAIL" ]] || die "--naive-email is required for real install"
      ;;
    all)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for real all install"
      [[ -n "$RIXXX_PROXY_DOMAIN" ]] || die "--rixxx-domain is required for real all install"
      [[ -n "$RIXXX_PROXY_EMAIL" ]] || die "--rixxx-email is required for real all install"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for real all install"
      ;;
    rixxx)
      [[ -n "$RIXXX_PROXY_DOMAIN" ]] || die "--domain is required for real RIXXX install"
      [[ -n "$RIXXX_PROXY_EMAIL" ]] || die "--proxy-email is required for real RIXXX install"
      ;;
    *) die "Real install currently supports --mode all, --mode both, or --mode rixxx" ;;
  esac
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
RIXXX domain:   ${RIXXX_PROXY_DOMAIN:-not set}
RIXXX email:    ${RIXXX_PROXY_EMAIL:-not set}

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
RIXXX domain:   ${RIXXX_PROXY_DOMAIN:-not set}
RIXXX email:    ${RIXXX_PROXY_EMAIL:-not set}

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

Legacy NaiveProxy-only mode:
- the old standalone NaiveProxy component has been removed;
- use --mode rixxx for RIXXX Panel + NaiveProxy + Hysteria2;
- use --mode all for 3x-ui + RIXXX Panel + NaiveProxy + Hysteria2.
EOF
      ;;
    both)
      cat <<'EOF'

Legacy both mode:
- kept as compatibility alias for older commands;
- new all-in-one installs should use --mode all;
- the old standalone NaiveProxy backend is not used.
EOF
      ;;
    all)
      cat <<EOF

All-in-one layout:
- x-ui-pro/nginx owns public 443/tcp.
- RIXXX NaiveProxy/Caddy runs as caddy-rixxx on 127.0.0.1:9445.
- nginx stream routes the RIXXX/NaiveProxy domain by SNI to 127.0.0.1:9445.
- Hysteria2 listens on public 443/udp.
- RIXXX panel runs as panel-naive-hy2 and is exposed by nginx on 8081 by default.
EOF
      ;;
    rixxx)
      cat <<EOF

RIXXX standalone panel actions:
- install the RIXXX Node.js panel from the vendored component;
- install selected stack: ${RIXXX_STACK};
- use proxy domain ${RIXXX_PROXY_DOMAIN} and email ${RIXXX_PROXY_EMAIL};
- expose panel with access mode ${RIXXX_ACCESS};
- use masquerade mode ${RIXXX_MASQUERADE} ${RIXXX_MASQUERADE_URL};
- Caddy will own public 443/tcp for NaiveProxy and Hysteria2 will use 443/udp when enabled.

This mode is standalone. Do not combine it with the x-ui/nginx unified layout on the same public 443 without manual review.
EOF
      ;;
  esac
}

run_real_install() {
  [[ "$REAL_INSTALL" == "1" ]] || return 0

  if [[ "$MODE" == "all" ]]; then
    local installer="$PROJECT_DIR/install-unified.sh"
    [[ -f "$installer" ]] || die "Real installer not found: $installer. Pull latest project version."

    cat <<EOF

Real all-in-one install requested
---------------------------------
Installer:      $installer
x-ui domain:    $XUI_DOMAIN
RIXXX domain:   $RIXXX_PROXY_DOMAIN
REALITY dest:   $REALITY_DEST
RIXXX email:    $RIXXX_PROXY_EMAIL

This will install 3x-ui + RIXXX Panel + NaiveProxy + Hysteria2.
EOF

    bash "$installer" --mode all \
      --xui-domain "$XUI_DOMAIN" \
      --rixxx-domain "$RIXXX_PROXY_DOMAIN" \
      --reality-dest "$REALITY_DEST" \
      --rixxx-email "$RIXXX_PROXY_EMAIL" \
      --panel-access "$RIXXX_ACCESS" \
      --yes
    return 0
  fi

  if [[ "$MODE" == "rixxx" ]]; then
    local rixxx_installer="$PROJECT_DIR/components/rixxx-panel/install.sh"
    [[ -f "$rixxx_installer" ]] || die "RIXXX installer not found: $rixxx_installer. Pull latest repository version."

    cat <<EOF

Real RIXXX panel install requested
----------------------------------
Installer:      $rixxx_installer
Stack:          $RIXXX_STACK
Access:         $RIXXX_ACCESS
Proxy domain:   $RIXXX_PROXY_DOMAIN
Proxy email:    $RIXXX_PROXY_EMAIL
Panel domain:   ${RIXXX_PANEL_DOMAIN:-not used}
EOF

    local -a rixxx_args=(
      --stack "$RIXXX_STACK"
      --access "$RIXXX_ACCESS"
      --domain "$RIXXX_PROXY_DOMAIN"
      --email "$RIXXX_PROXY_EMAIL"
      --masquerade "$RIXXX_MASQUERADE"
      --yes
    )
    [[ -n "$RIXXX_PANEL_DOMAIN" ]] && rixxx_args+=(--panel-domain "$RIXXX_PANEL_DOMAIN")
    [[ -n "$RIXXX_PANEL_EMAIL" ]] && rixxx_args+=(--panel-email "$RIXXX_PANEL_EMAIL")
    [[ "$RIXXX_SSH_ONLY" == "1" ]] && rixxx_args+=(--ssh-only)
    [[ -n "$RIXXX_MASQUERADE_URL" ]] && rixxx_args+=(--masquerade-url "$RIXXX_MASQUERADE_URL")
    [[ "$RIXXX_ALLOW_PORT_CONFLICT" == "1" ]] && rixxx_args+=(--allow-port-conflict)

    bash "$rixxx_installer" "${rixxx_args[@]}"
    return 0
  fi

  local installer="$PROJECT_DIR/install-unified.sh"
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
    --domain|--proxy-domain|--rixxx-domain) RIXXX_PROXY_DOMAIN="${2:-}"; shift 2 ;;
    --rixxx-email|--proxy-email) RIXXX_PROXY_EMAIL="${2:-}"; shift 2 ;;
    --rixxx-stack) RIXXX_STACK="${2:-}"; shift 2 ;;
    --rixxx-access) RIXXX_ACCESS="${2:-}"; shift 2 ;;
    --panel-domain|--rixxx-panel-domain) RIXXX_PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --panel-email|--rixxx-panel-email) RIXXX_PANEL_EMAIL="${2:-}"; shift 2 ;;
    --ssh-only|--rixxx-ssh-only) RIXXX_SSH_ONLY=1; shift ;;
    --masquerade|--rixxx-masquerade) RIXXX_MASQUERADE="${2:-}"; shift 2 ;;
    --masquerade-url|--rixxx-masquerade-url) RIXXX_MASQUERADE_URL="${2:-}"; shift 2 ;;
    --allow-port-conflict|--rixxx-allow-port-conflict) RIXXX_ALLOW_PORT_CONFLICT=1; shift ;;
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
  [[ -n "$MODE" ]] || MODE="all"
  collect_real_install_inputs
else
  collect_interactive_inputs
fi
case "$MODE" in xui|naive|all|both|rixxx) ;; *) die "--mode must be xui, naive, all, both, or rixxx" ;; esac

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
  all)
    check_domain "$XUI_DOMAIN" "x-ui"
    check_domain "$RIXXX_PROXY_DOMAIN" "RIXXX/NaiveProxy"
    check_domain "$REALITY_DEST" "REALITY destination"
    ;;
  rixxx)
    check_domain "$RIXXX_PROXY_DOMAIN" "RIXXX proxy"
    [[ -n "$RIXXX_PANEL_DOMAIN" ]] && check_domain "$RIXXX_PANEL_DOMAIN" "RIXXX panel"
    ;;
esac

print_plan
run_real_install
