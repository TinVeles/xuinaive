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
NH_PROXY_DOMAIN="${NH_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}"
NH_PROXY_EMAIL="${NH_PROXY_EMAIL:-${PROXY_EMAIL:-}}"
NH_STACK="${NH_STACK:-both}"
NH_ACCESS="${NH_ACCESS:-nginx8080}"
NH_PANEL_DOMAIN="${NH_PANEL_DOMAIN:-${PANEL_DOMAIN:-}}"
NH_PANEL_EMAIL="${NH_PANEL_EMAIL:-${PANEL_EMAIL:-}}"
NH_SSH_ONLY="${NH_SSH_ONLY:-0}"
NH_MASQUERADE="${NH_MASQUERADE:-local}"
NH_MASQUERADE_URL="${NH_MASQUERADE_URL:-}"
NH_ALLOW_PORT_CONFLICT="${NH_ALLOW_PORT_CONFLICT:-0}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
INSTALL_WARP="${INSTALL_WARP:-0}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-inbound-443}"
WARP_ROUTE_PORT="${WARP_ROUTE_PORT:-443}"
GENERATE_PROFILES="${GENERATE_PROFILES:-0}"
PROFILE_COUNT="${PROFILE_COUNT:-15}"
PROFILE_PREFIX="${PROFILE_PREFIX:-auto}"
PROJECT_DIR="${UPM_PROJECT_DIR:-$SCRIPT_DIR}"
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
  ./install.sh --mode all --xui-domain x.example.com --nh-domain n.example.com --reality-dest r.example.com --nh-email admin@example.com --install --yes
  ./install.sh --mode all --xui-domain x.example.com --nh-domain n.example.com --reality-dest r.example.com --nh-email admin@example.com --install-warp --install --yes
  ./install.sh --mode all --xui-domain x.example.com --nh-domain n.example.com --reality-dest r.example.com --nh-email admin@example.com --install-warp --generate-profiles --install --yes
  ./install.sh --mode all --xui-domain x.example.com --nh-domain n.example.com --reality-dest r.example.com --nh-email admin@example.com --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem --install --yes
  ./install.sh --mode nh --domain vpn.example.com --proxy-email admin@example.com --install --yes
  bash <(wget -qO- RAW_INSTALL_URL)

Default mode is dry-run only. Real install requires --install --yes.
When values are omitted in an interactive terminal, the script asks for them.
When run from a URL, relative paths are resolved from the current directory or --project-dir.
Mode all installs 3x-ui + N+H Panel + NaiveProxy + Hysteria2 on one VPS.
Mode nh installs only the standalone N+H NaiveProxy + Hysteria2 web panel.
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

  while [[ -z "$current_value" ]]; do
    require_interactive
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
    echo "  3) all   - 3x-ui + N+H Panel + NaiveProxy + Hysteria2"
    echo "  4) both  - legacy x-ui + NaiveProxy plan"
    echo "  5) nh - N+H NaiveProxy + Hysteria2 web panel only"
    read -r -p "Mode [xui/naive/all/both/nh or 1/2/3/4/5]: " input
    case "$input" in
      1|xui) MODE="xui" ;;
      2|naive) MODE="naive" ;;
      3|all) MODE="all" ;;
      4|both) MODE="both" ;;
      5|nh) MODE="nh" ;;
      *) warn "Please enter xui, naive, all, both, nh, 1, 2, 3, 4, or 5." ;;
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
      prompt_value NH_PROXY_DOMAIN "Enter N+H/NaiveProxy domain, for example naive.example.com" "$NH_PROXY_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example reality.example.com" "$REALITY_DEST"
      prompt_value NH_PROXY_EMAIL "Enter email for Caddy/Let's Encrypt" "$NH_PROXY_EMAIL"
      ;;
    nh)
      prompt_value NH_PROXY_DOMAIN "Enter N+H proxy domain, for example vpn.example.com" "$NH_PROXY_DOMAIN"
      prompt_value NH_PROXY_EMAIL "Enter email for Let's Encrypt" "$NH_PROXY_EMAIL"
      ;;
    *) die "--mode must be xui, naive, all, both, or nh" ;;
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
      prompt_value NH_PROXY_DOMAIN "Enter N+H/NaiveProxy domain, for example naive.example.com" "$NH_PROXY_DOMAIN"
      prompt_value REALITY_DEST "Enter REALITY destination domain, for example reality.example.com" "$REALITY_DEST"
      prompt_value NH_PROXY_EMAIL "Enter email for Caddy/Let's Encrypt" "$NH_PROXY_EMAIL"
      ;;
    nh)
      prompt_value NH_PROXY_DOMAIN "Enter N+H proxy domain, for example vpn.example.com" "$NH_PROXY_DOMAIN"
      prompt_value NH_PROXY_EMAIL "Enter email for Let's Encrypt" "$NH_PROXY_EMAIL"
      ;;
    *) die "Real install currently supports --mode all, --mode both, or --mode nh" ;;
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
  if [[ "$INSTALL_WARP" == "1" ]]; then
    details="$(port_details "$WARP_PROXY_PORT")"
    if [[ -n "$details" ]]; then
      warn "Port $WARP_PROXY_PORT is busy:"
      printf '%s\n' "$details"
    else
      ok "Port $WARP_PROXY_PORT is free or listener was not detected"
    fi
  fi
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
  service_line caddy-nh
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

check_vendored_components() {
  local missing=0
  local path
  for path in \
    "$PROJECT_DIR/install-unified.sh" \
    "$PROJECT_DIR/install-warp.sh" \
    "$PROJECT_DIR/generate-profiles.sh" \
    "$PROJECT_DIR/components/x-ui-pro/x-ui-pro.sh" \
    "$PROJECT_DIR/components/x-ui-pro/apply-naive-sni-route.sh" \
    "$PROJECT_DIR/components/nh-panel/install.sh" \
    "$PROJECT_DIR/components/nh-panel/install-unified-backend.sh" \
    "$PROJECT_DIR/components/nh-panel/update.sh" \
    "$PROJECT_DIR/components/nh-panel/upstream/install.sh" \
    "$PROJECT_DIR/components/nh-panel/upstream/update.sh"; do
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
      [[ -n "$NH_PROXY_DOMAIN" ]] || die "--nh-domain is required for --mode all"
      [[ -n "$NH_PROXY_EMAIL" ]] || die "--nh-email is required for --mode all"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for --mode all"
      ;;
    nh)
      [[ -n "$NH_PROXY_DOMAIN" ]] || die "--domain is required for --mode nh"
      [[ -n "$NH_PROXY_EMAIL" ]] || die "--proxy-email is required for --mode nh"
      ;;
    *) die "--mode must be xui, naive, all, both, or nh" ;;
  esac
}

validate_real_install_args() {
  [[ "$REAL_INSTALL" == "1" ]] || return 0
  [[ "$WARP_PROXY_PORT" =~ ^[0-9]+$ ]] || die "--warp-proxy-port must be numeric"
  [[ "$WARP_ROUTE_PORT" =~ ^[0-9]+$ ]] || die "--warp-route-port must be numeric"
  [[ "$PROFILE_COUNT" =~ ^[0-9]+$ && "$PROFILE_COUNT" -gt 0 ]] || die "--profile-count must be a positive number"
  [[ "$PROFILE_PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--profile-prefix may contain only A-Z, a-z, 0-9, dot, underscore, and dash"
  if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
    [[ -f "$TLS_CERT" ]] || die "--tls-cert file not found: $TLS_CERT"
    [[ -f "$TLS_KEY" ]] || die "--tls-key file not found: $TLS_KEY"
  fi
  case "$MODE" in
    both)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for real install"
      [[ -n "$NAIVE_DOMAIN" ]] || die "--naive-domain is required for real install"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for real install"
      [[ -n "$NAIVE_EMAIL" ]] || die "--naive-email is required for real install"
      ;;
    all)
      [[ -n "$XUI_DOMAIN" ]] || die "--xui-domain is required for real all install"
      [[ -n "$NH_PROXY_DOMAIN" ]] || die "--nh-domain is required for real all install"
      [[ -n "$NH_PROXY_EMAIL" ]] || die "--nh-email is required for real all install"
      [[ -n "$REALITY_DEST" ]] || die "--reality-dest is required for real all install"
      ;;
    nh)
      [[ -n "$NH_PROXY_DOMAIN" ]] || die "--domain is required for real N+H install"
      [[ -n "$NH_PROXY_EMAIL" ]] || die "--proxy-email is required for real N+H install"
      ;;
    *) die "Real install currently supports --mode all, --mode both, or --mode nh" ;;
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
N+H domain:   ${NH_PROXY_DOMAIN:-not set}
N+H email:    ${NH_PROXY_EMAIL:-not set}
TLS cert:       ${TLS_CERT:-auto/ACME}
TLS key:        ${TLS_KEY:-auto/ACME}
Install WARP:   ${INSTALL_WARP}
WARP proxy:     127.0.0.1:${WARP_PROXY_PORT}
Profiles:       ${GENERATE_PROFILES} (${PROFILE_COUNT} per group, prefix ${PROFILE_PREFIX})

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
x-ui domain:    ${XUI_DOMAIN:-not set}
Naive domain:   ${NAIVE_DOMAIN:-not set}
REALITY dest:   ${REALITY_DEST:-not set}
Naive email:    ${NAIVE_EMAIL:-not set}
N+H domain:   ${NH_PROXY_DOMAIN:-not set}
N+H email:    ${NH_PROXY_EMAIL:-not set}
TLS cert:       ${TLS_CERT:-auto/ACME}
TLS key:        ${TLS_KEY:-auto/ACME}
Install WARP:   ${INSTALL_WARP}
WARP proxy:     127.0.0.1:${WARP_PROXY_PORT}
Profiles:       ${GENERATE_PROFILES} (${PROFILE_COUNT} per group, prefix ${PROFILE_PREFIX})

No changes will be made.
No packages will be installed.
No services will be started/stopped.
No vendored component scripts will be executed.
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
- use --mode nh for N+H Panel + NaiveProxy + Hysteria2;
- use --mode all for 3x-ui + N+H Panel + NaiveProxy + Hysteria2.
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
- N+H NaiveProxy/Caddy runs as caddy-nh on 127.0.0.1:9445.
- nginx stream routes the N+H/NaiveProxy domain by SNI to 127.0.0.1:9445.
- N+H TLS is issued automatically unless --tls-cert/--tls-key are provided.
- Caddy accepts nginx stream PROXY protocol on the backend listener.
- Hysteria2 listens on public 443/udp.
- N+H panel runs as panel-naive-hy2 and is exposed by nginx on 8081 by default.
- Optional WARP local proxy installs on 127.0.0.1:${WARP_PROXY_PORT} when --install-warp is used.
- Optional profile generator creates ${PROFILE_COUNT} shared-email direct x-ui profiles, ${PROFILE_COUNT} shared-email WARP x-ui profiles, plus ${PROFILE_COUNT} NaiveProxy and ${PROFILE_COUNT} Hy2 profiles when --generate-profiles is used.
EOF
      ;;
    nh)
      cat <<EOF

N+H standalone panel actions:
- install the N+H Node.js panel from the vendored component;
- install selected stack: ${NH_STACK};
- use proxy domain ${NH_PROXY_DOMAIN} and email ${NH_PROXY_EMAIL};
- expose panel with access mode ${NH_ACCESS};
- use masquerade mode ${NH_MASQUERADE} ${NH_MASQUERADE_URL};
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
N+H domain:   $NH_PROXY_DOMAIN
REALITY dest:   $REALITY_DEST
N+H email:    $NH_PROXY_EMAIL

This will install 3x-ui + N+H Panel + NaiveProxy + Hysteria2.
EOF

    local -a all_args=(
      --mode all
      --xui-domain "$XUI_DOMAIN"
      --nh-domain "$NH_PROXY_DOMAIN"
      --reality-dest "$REALITY_DEST"
      --nh-email "$NH_PROXY_EMAIL"
      --panel-access "$NH_ACCESS"
      --yes
    )
    [[ -n "$TLS_CERT" ]] && all_args+=(--tls-cert "$TLS_CERT")
    [[ -n "$TLS_KEY" ]] && all_args+=(--tls-key "$TLS_KEY")
    bash "$installer" "${all_args[@]}"
    run_warp_install_if_requested
    run_profile_generation_if_requested
    return 0
  fi

  if [[ "$MODE" == "nh" ]]; then
    local nh_installer="$PROJECT_DIR/components/nh-panel/install.sh"
    [[ -f "$nh_installer" ]] || die "N+H installer not found: $nh_installer. Pull latest repository version."

    cat <<EOF

Real N+H panel install requested
----------------------------------
Installer:      $nh_installer
Stack:          $NH_STACK
Access:         $NH_ACCESS
Proxy domain:   $NH_PROXY_DOMAIN
Proxy email:    $NH_PROXY_EMAIL
Panel domain:   ${NH_PANEL_DOMAIN:-not used}
EOF

    local -a nh_args=(
      --stack "$NH_STACK"
      --access "$NH_ACCESS"
      --domain "$NH_PROXY_DOMAIN"
      --email "$NH_PROXY_EMAIL"
      --masquerade "$NH_MASQUERADE"
      --yes
    )
    [[ -n "$NH_PANEL_DOMAIN" ]] && nh_args+=(--panel-domain "$NH_PANEL_DOMAIN")
    [[ -n "$NH_PANEL_EMAIL" ]] && nh_args+=(--panel-email "$NH_PANEL_EMAIL")
    [[ "$NH_SSH_ONLY" == "1" ]] && nh_args+=(--ssh-only)
    [[ -n "$NH_MASQUERADE_URL" ]] && nh_args+=(--masquerade-url "$NH_MASQUERADE_URL")
    [[ "$NH_ALLOW_PORT_CONFLICT" == "1" ]] && nh_args+=(--allow-port-conflict)

    bash "$nh_installer" "${nh_args[@]}"
    run_warp_install_if_requested
    run_profile_generation_if_requested
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
  run_warp_install_if_requested
  run_profile_generation_if_requested
}

run_warp_install_if_requested() {
  [[ "$INSTALL_WARP" == "1" ]] || return 0
  local warp_installer="$PROJECT_DIR/install-warp.sh"
  [[ -f "$warp_installer" ]] || die "WARP installer not found: $warp_installer"

  cat <<EOF

Installing optional WARP local proxy
------------------------------------
Installer:       $warp_installer
Proxy:           127.0.0.1:${WARP_PROXY_PORT}
Outbound tag:    ${WARP_OUTBOUND_TAG}
Inbound tag:     ${WARP_INBOUND_TAG}
Route port:      ${WARP_ROUTE_PORT}
EOF

  bash "$warp_installer" \
    --proxy-port "$WARP_PROXY_PORT" \
    --outbound-tag "$WARP_OUTBOUND_TAG" \
    --inbound-tag "$WARP_INBOUND_TAG" \
    --route-port "$WARP_ROUTE_PORT" \
    --yes
}

run_profile_generation_if_requested() {
  [[ "$GENERATE_PROFILES" == "1" ]] || return 0
  local profile_generator="$PROJECT_DIR/generate-profiles.sh"
  [[ -f "$profile_generator" ]] || die "Profile generator not found: $profile_generator"

  cat <<EOF

Generating clients and profiles
-------------------------------
Generator:       $profile_generator
Count:           $PROFILE_COUNT
Prefix:          $PROFILE_PREFIX
WARP outbound:   $WARP_OUTBOUND_TAG
WARP proxy:      127.0.0.1:${WARP_PROXY_PORT}
EOF

  bash "$profile_generator" \
    --count "$PROFILE_COUNT" \
    --prefix "$PROFILE_PREFIX" \
    --warp-port "$WARP_PROXY_PORT" \
    --warp-outbound-tag "$WARP_OUTBOUND_TAG" \
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
    --domain|--proxy-domain|--nh-domain) NH_PROXY_DOMAIN="${2:-}"; shift 2 ;;
    --nh-email|--proxy-email) NH_PROXY_EMAIL="${2:-}"; shift 2 ;;
    --nh-stack) NH_STACK="${2:-}"; shift 2 ;;
    --nh-access) NH_ACCESS="${2:-}"; shift 2 ;;
    --panel-domain|--nh-panel-domain) NH_PANEL_DOMAIN="${2:-}"; shift 2 ;;
    --panel-email|--nh-panel-email) NH_PANEL_EMAIL="${2:-}"; shift 2 ;;
    --ssh-only|--nh-ssh-only) NH_SSH_ONLY=1; shift ;;
    --masquerade|--nh-masquerade) NH_MASQUERADE="${2:-}"; shift 2 ;;
    --masquerade-url|--nh-masquerade-url) NH_MASQUERADE_URL="${2:-}"; shift 2 ;;
    --allow-port-conflict|--nh-allow-port-conflict) NH_ALLOW_PORT_CONFLICT=1; shift ;;
    --tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key) TLS_KEY="${2:-}"; shift 2 ;;
    --install-warp) INSTALL_WARP=1; shift ;;
    --warp-proxy-port) WARP_PROXY_PORT="${2:-}"; shift 2 ;;
    --warp-outbound-tag) WARP_OUTBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-inbound-tag) WARP_INBOUND_TAG="${2:-}"; shift 2 ;;
    --warp-route-port) WARP_ROUTE_PORT="${2:-}"; shift 2 ;;
    --generate-profiles) GENERATE_PROFILES=1; shift ;;
    --profile-count) PROFILE_COUNT="${2:-}"; shift 2 ;;
    --profile-prefix) PROFILE_PREFIX="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --install) REAL_INSTALL=1; DRY_RUN=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "$REAL_INSTALL" == "1" ]]; then
  [[ -n "$MODE" ]] || MODE="all"
  collect_real_install_inputs
else
  collect_interactive_inputs
fi
case "$MODE" in xui|naive|all|both|nh) ;; *) die "--mode must be xui, naive, all, both, or nh" ;; esac

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
check_vendored_components

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
    check_domain "$NH_PROXY_DOMAIN" "N+H/NaiveProxy"
    check_domain "$REALITY_DEST" "REALITY destination"
    ;;
  nh)
    check_domain "$NH_PROXY_DOMAIN" "N+H proxy"
    [[ -n "$NH_PANEL_DOMAIN" ]] && check_domain "$NH_PANEL_DOMAIN" "N+H panel"
    ;;
esac

print_plan
run_real_install
