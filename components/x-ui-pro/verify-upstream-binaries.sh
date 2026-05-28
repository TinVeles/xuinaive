#!/usr/bin/env bash
# Preflight verifier and runtime-patch generator for vendored x-ui-pro.sh.
#
# Responsibilities:
#   1. Resolve upstream artifact versions (from pins.env if present, else
#      probe GitHub API once and TOFU-lock into pins.lock).
#   2. Download every artifact wget'd by x-ui-pro.sh to a staging directory.
#   3. Verify SHA256 against pin (STRICT) or seed pin (TOFU first-use).
#   4. Emit a patched copy of x-ui-pro.sh in $UPM_X_UI_PRO_RUNTIME that
#      replaces the wget calls with `cp` from the verified staging area.
#   5. Print the patched script path on stdout (or set UPM_X_UI_PRO_RUNTIME).
#
# Exit non-zero on any integrity failure.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$UPM_ROOT/lib/common.sh"

PINS_ENV="${UPM_X_UI_PRO_PINS:-$SCRIPT_DIR/upstream-pins.env}"
PINS_LOCK="${UPM_X_UI_PRO_PINS_LOCK:-$SCRIPT_DIR/upstream-pins.lock}"
SOURCE_SCRIPT="${UPM_X_UI_PRO_SOURCE:-$SCRIPT_DIR/x-ui-pro.sh}"
STAGE_DIR="${UPM_X_UI_PRO_STAGE:-/var/tmp/upm-x-ui-prefetch}"
RUNTIME_SCRIPT="${UPM_X_UI_PRO_RUNTIME:-$STAGE_DIR/x-ui-pro.patched.sh}"
TOFU_DEFAULT="${UPM_X_UI_PRO_TOFU:-1}"
PRINT_CURRENT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-current) PRINT_CURRENT=1; shift ;;
    --strict) TOFU_DEFAULT=0; shift ;;
    --pins) PINS_ENV="${2:-}"; shift 2 ;;
    --lock) PINS_LOCK="${2:-}"; shift 2 ;;
    --source) SOURCE_SCRIPT="${2:-}"; shift 2 ;;
    --runtime) RUNTIME_SCRIPT="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: verify-upstream-binaries.sh [options]
  --print-current     Download and print SHA256 of current upstream artifacts; do not patch
  --strict            Refuse to TOFU; require populated pins env
  --pins FILE         Path to pins env file (default: $PINS_ENV)
  --lock FILE         Path to pins lock file (default: $PINS_LOCK)
  --source FILE       Path to vendored x-ui-pro.sh (default: $SOURCE_SCRIPT)
  --runtime FILE      Where to write patched copy (default: $RUNTIME_SCRIPT)
EOF
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command_exists curl || die "curl required"
command_exists sha256sum || die "sha256sum required"
command_exists sed || die "sed required"
[[ -f "$SOURCE_SCRIPT" ]] || die "x-ui-pro.sh not found: $SOURCE_SCRIPT"

arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

resolve_latest_x_ui() {
  curl -fsSL "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
    | grep -oE '"tag_name"\s*:\s*"[^"]+"' | head -n1 | cut -d'"' -f4
}

download_to() {
  local url="$1" dest="$2"
  upm_log_info "Fetching $url"
  curl -fSL --retry 3 --connect-timeout 10 -o "$dest" "$url" \
    || die "Download failed: $url"
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

verify_or_seed() {
  local label="$1" file="$2" expected="$3"
  local actual
  actual="$(sha256_of "$file")"
  if [[ -n "$expected" ]]; then
    [[ "$actual" == "$expected" ]] \
      || die "SHA256 mismatch for $label: expected=$expected actual=$actual file=$file"
    upm_log_ok "$label SHA256 verified: $actual"
  else
    [[ "$TOFU_DEFAULT" == "1" ]] \
      || die "$label has no pinned SHA256 and --strict was requested"
    upm_log_warn "$label SHA256 not pinned; recording TOFU value: $actual"
    printf '%s\n' "$actual"
  fi
}

ARCH="$(arch_tag)"
mkdir -p "$STAGE_DIR"
chmod 0700 "$STAGE_DIR"

X_UI_VERSION=""
X_UI_TAR_SHA256_AMD64=""
X_UI_TAR_SHA256_ARM64=""
X_UI_SH_SHA256=""
X_UI_RC_SHA256=""
SUB2SINGBOX_VERSION="v0.0.9"
SUB2SINGBOX_TAR_SHA256_AMD64=""
SUB2SINGBOX_TAR_SHA256_ARM64=""

if [[ -f "$PINS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$PINS_ENV"
elif [[ -f "$PINS_LOCK" ]]; then
  # shellcheck disable=SC1090
  source "$PINS_LOCK"
fi

[[ -n "$X_UI_VERSION" ]] || X_UI_VERSION="$(resolve_latest_x_ui)"
[[ -n "$X_UI_VERSION" ]] || die "Could not resolve x-ui release version"

X_UI_TAR_URL="https://github.com/MHSanaei/3x-ui/releases/download/${X_UI_VERSION}/x-ui-linux-${ARCH}.tar.gz"
X_UI_SH_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"
X_UI_RC_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc"
SUB2SINGBOX_URL="https://github.com/legiz-ru/sub2sing-box/releases/download/${SUB2SINGBOX_VERSION}/sub2sing-box_${SUB2SINGBOX_VERSION#v}_linux_${ARCH}.tar.gz"

X_UI_TAR_FILE="$STAGE_DIR/x-ui-linux-${ARCH}.tar.gz"
X_UI_SH_FILE="$STAGE_DIR/x-ui.sh"
X_UI_RC_FILE="$STAGE_DIR/x-ui.rc"
SUB2SINGBOX_FILE="$STAGE_DIR/sub2sing-box_${SUB2SINGBOX_VERSION#v}_linux_${ARCH}.tar.gz"

download_to "$X_UI_TAR_URL" "$X_UI_TAR_FILE"
download_to "$X_UI_SH_URL" "$X_UI_SH_FILE"
download_to "$X_UI_RC_URL" "$X_UI_RC_FILE"
download_to "$SUB2SINGBOX_URL" "$SUB2SINGBOX_FILE"

if [[ "$PRINT_CURRENT" == "1" ]]; then
  printf 'X_UI_VERSION="%s"\n' "$X_UI_VERSION"
  printf 'X_UI_TAR_SHA256_%s="%s"\n' "${ARCH^^}" "$(sha256_of "$X_UI_TAR_FILE")"
  printf 'X_UI_SH_SHA256="%s"\n' "$(sha256_of "$X_UI_SH_FILE")"
  printf 'X_UI_RC_SHA256="%s"\n' "$(sha256_of "$X_UI_RC_FILE")"
  printf 'SUB2SINGBOX_VERSION="%s"\n' "$SUB2SINGBOX_VERSION"
  printf 'SUB2SINGBOX_TAR_SHA256_%s="%s"\n' "${ARCH^^}" "$(sha256_of "$SUB2SINGBOX_FILE")"
  exit 0
fi

if [[ "$ARCH" == "amd64" ]]; then
  X_UI_TAR_PIN="$X_UI_TAR_SHA256_AMD64"
  SUB2SINGBOX_PIN="$SUB2SINGBOX_TAR_SHA256_AMD64"
else
  X_UI_TAR_PIN="$X_UI_TAR_SHA256_ARM64"
  SUB2SINGBOX_PIN="$SUB2SINGBOX_TAR_SHA256_ARM64"
fi

X_UI_TAR_NEW_PIN="$(verify_or_seed "x-ui tar (${ARCH})" "$X_UI_TAR_FILE" "$X_UI_TAR_PIN")"
X_UI_SH_NEW_PIN="$(verify_or_seed "x-ui.sh" "$X_UI_SH_FILE" "$X_UI_SH_SHA256")"
X_UI_RC_NEW_PIN="$(verify_or_seed "x-ui.rc" "$X_UI_RC_FILE" "$X_UI_RC_SHA256")"
SUB2SINGBOX_NEW_PIN="$(verify_or_seed "sub2sing-box (${ARCH})" "$SUB2SINGBOX_FILE" "$SUB2SINGBOX_PIN")"

if [[ ! -f "$PINS_ENV" ]]; then
  TMP_LOCK="$(mktemp)"
  {
    printf '# Auto-generated TOFU lock. Review and promote to upstream-pins.env when stable.\n'
    printf 'X_UI_VERSION="%s"\n' "$X_UI_VERSION"
    printf 'X_UI_TAR_SHA256_%s="%s"\n' "${ARCH^^}" "${X_UI_TAR_PIN:-$X_UI_TAR_NEW_PIN}"
    printf 'X_UI_SH_SHA256="%s"\n' "${X_UI_SH_SHA256:-$X_UI_SH_NEW_PIN}"
    printf 'X_UI_RC_SHA256="%s"\n' "${X_UI_RC_SHA256:-$X_UI_RC_NEW_PIN}"
    printf 'SUB2SINGBOX_VERSION="%s"\n' "$SUB2SINGBOX_VERSION"
    printf 'SUB2SINGBOX_TAR_SHA256_%s="%s"\n' "${ARCH^^}" "${SUB2SINGBOX_PIN:-$SUB2SINGBOX_NEW_PIN}"
  } > "$TMP_LOCK"
  install -m 0600 "$TMP_LOCK" "$PINS_LOCK"
  rm -f "$TMP_LOCK"
  upm_log_ok "Wrote TOFU pins to $PINS_LOCK"
fi

upm_log_info "Patching x-ui-pro.sh -> $RUNTIME_SCRIPT"
mkdir -p "$(dirname "$RUNTIME_SCRIPT")"
{
  printf '#!/bin/bash\n'
  printf '# Auto-generated runtime copy with verified prefetched downloads.\n'
  printf 'export UPM_X_UI_VERSION=%q\n' "$X_UI_VERSION"
  printf 'export UPM_X_UI_PREFETCH=%q\n' "$STAGE_DIR"
  sed \
    -e "s|tag_version=\$(curl[^)]*)|tag_version=\"$X_UI_VERSION\"|" \
    -e "s|wget -N -O /usr/local/x-ui-linux-\$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/\${tag_version}/x-ui-linux-\$(arch).tar.gz|cp -f \"$X_UI_TAR_FILE\" /usr/local/x-ui-linux-\$(arch).tar.gz|" \
    -e "s|wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh|cp -f \"$X_UI_SH_FILE\" /usr/bin/x-ui-temp|" \
    -e "s|wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc|cp -f \"$X_UI_RC_FILE\" /etc/init.d/x-ui|" \
    -e "s|wget -P /root/ https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz|cp -f \"$SUB2SINGBOX_FILE\" /root/$(basename "$SUB2SINGBOX_FILE")|" \
    "$SOURCE_SCRIPT" | tail -n +2
} > "${RUNTIME_SCRIPT}.tmp"
chmod 0755 "${RUNTIME_SCRIPT}.tmp"
mv -f "${RUNTIME_SCRIPT}.tmp" "$RUNTIME_SCRIPT"

upm_log_ok "Verified upstream artifacts; patched runner at $RUNTIME_SCRIPT"
printf '%s\n' "$RUNTIME_SCRIPT"
