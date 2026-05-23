#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/TinVeles/xuinaive.git}"
APP_DIR="${APP_DIR:-/root/unified-proxy-manager}"

XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"

WARP_PROXY_HOST="${WARP_PROXY_HOST:-127.0.0.1}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
WARP_OUTBOUND_TAG="${WARP_OUTBOUND_TAG:-warp-cli}"
XUI_APPLY_WARP_TEMPLATE="${XUI_APPLY_WARP_TEMPLATE:-0}"
XUI_CLEANUP_WARP_TEMPLATE="${XUI_CLEANUP_WARP_TEMPLATE:-0}"

# all = правило без inboundTag, то есть работает для всех inbounds.
# generated = только для сгенерированных preset inbound tags.
WARP_INBOUND_TAG="${WARP_INBOUND_TAG:-all}"

PROFILE_COUNT="${PROFILE_COUNT:-15}"
PROFILE_PREFIX="${PROFILE_PREFIX:-auto}"

WARP_AI_DOMAINS="${WARP_AI_DOMAINS:-domain:openai.com,domain:chatgpt.com,domain:oaistatic.com,domain:oaiusercontent.com,domain:anthropic.com,domain:claude.ai,domain:gemini.google.com,domain:aistudio.google.com,domain:ai.google.dev,domain:generativelanguage.googleapis.com,domain:aiplatform.googleapis.com,domain:googleapis.com,domain:gstatic.com,domain:googleusercontent.com,domain:ggpht.com,domain:clients6.google.com,domain:accounts.google.com,domain:apis.google.com,domain:ogs.google.com,domain:www.google.com,domain:play.google.com,domain:withgoogle.com,domain:youtube.com,domain:ytimg.com,domain:notebooklm.google.com,domain:notebooklm.google}"

log()  { printf '\033[0;34mINFO:\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32mOK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Запусти от root: sudo bash $0"
}

install_base_packages() {
  log "Installing required packages"
  apt-get update
  apt-get install -y git curl jq sqlite3 ca-certificates lsb-release
}

prepare_repo() {
  if [[ ! -d "$APP_DIR/.git" ]]; then
    log "Cloning repository to $APP_DIR"
    rm -rf "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
  else
    log "Repository exists: $APP_DIR"
    git -C "$APP_DIR" pull --ff-only || warn "Не удалось обновить repo через git pull; продолжаю с текущей версией."
  fi

  [[ -f "$APP_DIR/install-warp.sh" ]] || die "Не найден $APP_DIR/install-warp.sh"
  [[ -f "$APP_DIR/generate-profiles.sh" ]] || die "Не найден $APP_DIR/generate-profiles.sh"
}

backup_xui_db() {
  if [[ -f "$XUI_DB" ]]; then
    local backup="/root/x-ui.db.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$XUI_DB" "$backup"
    ok "Backup x-ui DB: $backup"
  else
    warn "x-ui DB не найдена: $XUI_DB"
    warn "WARP будет установлен, но routing в x-ui применить не получится."
  fi
}

install_warp_proxy() {
  log "Installing Cloudflare WARP local proxy on ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}"

  cd "$APP_DIR"

  WARP_PROXY_PORT="$WARP_PROXY_PORT" \
  WARP_OUTBOUND_TAG="$WARP_OUTBOUND_TAG" \
  WARP_INBOUND_TAG="$WARP_INBOUND_TAG" \
  WARP_AI_DOMAINS="$WARP_AI_DOMAINS" \
  bash install-warp.sh \
    --proxy-port "$WARP_PROXY_PORT" \
    --outbound-tag "$WARP_OUTBOUND_TAG" \
    --warp-ai-domains "$WARP_AI_DOMAINS" \
    --yes
}

test_warp_proxy() {
  log "Testing WARP proxy"

  if ss -lntp | grep -q ":${WARP_PROXY_PORT}"; then
    ok "Local WARP proxy listens on ${WARP_PROXY_HOST}:${WARP_PROXY_PORT}"
  else
    warn "Не вижу listener на ${WARP_PROXY_PORT}. Проверка через curl всё равно будет выполнена."
  fi

  local trace
  trace="$(curl -fsS --max-time 25 --socks5-hostname "${WARP_PROXY_HOST}:${WARP_PROXY_PORT}" https://www.cloudflare.com/cdn-cgi/trace || true)"

  if grep -qi '^warp=on' <<<"$trace" || grep -qi '^warp=plus' <<<"$trace"; then
    ok "Cloudflare trace confirms WARP:"
    printf '%s\n' "$trace" | grep -E 'ip=|colo=|warp=' || true
  else
    warn "Cloudflare trace не подтвердил warp=on/plus."
    printf '%s\n' "$trace" || true
  fi
}

write_xui_warp_snippet() {
  [[ -f "$XUI_DB" ]] || {
    warn "Пропускаю x-ui snippet: нет $XUI_DB"
    return 0
  }

  if [[ "$XUI_APPLY_WARP_TEMPLATE" == "1" ]]; then
    warn "XUI_APPLY_WARP_TEMPLATE=1: будет изменён x-ui routing template DB. Этот режим экспериментальный."
  else
    log "Writing x-ui/Xray WARP snippet only; x-ui DB routing template will not be modified"
  fi

  cd "$APP_DIR"

  local -a args=(
    --xui-only
    --count "$PROFILE_COUNT"
    --prefix "$PROFILE_PREFIX"
    --warp-port "$WARP_PROXY_PORT"
    --warp-outbound-tag "$WARP_OUTBOUND_TAG"
    --yes
  )
  [[ "$XUI_APPLY_WARP_TEMPLATE" == "1" ]] && args+=(--apply-xui-warp-template)
  [[ "$XUI_CLEANUP_WARP_TEMPLATE" == "1" ]] && args+=(--cleanup-xui-warp-template --no-xui-warp-routing)

  XUI_ENABLE_WARP_ROUTING=1 \
  XUI_APPLY_WARP_TEMPLATE="$XUI_APPLY_WARP_TEMPLATE" \
  XUI_CLEANUP_WARP_TEMPLATE="$XUI_CLEANUP_WARP_TEMPLATE" \
  XUI_AUTO_INSTALL_WARP=0 \
  XUI_CREATE_DIRECT=1 \
  XUI_DB="$XUI_DB" \
  WARP_PROXY_HOST="$WARP_PROXY_HOST" \
  WARP_PROXY_PORT="$WARP_PROXY_PORT" \
  WARP_OUTBOUND_TAG="$WARP_OUTBOUND_TAG" \
  WARP_INBOUND_TAG="$WARP_INBOUND_TAG" \
  WARP_AI_DOMAINS="$WARP_AI_DOMAINS" \
  bash generate-profiles.sh "${args[@]}"

  if [[ -f /etc/x-ui/warp-generated-routing.json ]]; then
    ok "Generated routing snippet:"
    jq . /etc/x-ui/warp-generated-routing.json || cat /etc/x-ui/warp-generated-routing.json
  fi
}

restart_services() {
  log "Restarting x-ui"

  if systemctl list-unit-files | grep -q '^x-ui\.service'; then
    systemctl restart x-ui
    systemctl status x-ui --no-pager -l || true
    ok "x-ui restarted"
  else
    warn "systemd service x-ui не найден. Перезапусти панель вручную, если она называется иначе."
  fi

  systemctl status warp-svc --no-pager -l || true
}

main() {
  need_root
  install_base_packages
  prepare_repo
  backup_xui_db
  install_warp_proxy
  test_warp_proxy
  write_xui_warp_snippet
  restart_services

  ok "Done."
  echo
  echo "Проверка WARP:"
  echo "  curl --socks5-hostname ${WARP_PROXY_HOST}:${WARP_PROXY_PORT} https://www.cloudflare.com/cdn-cgi/trace"
  echo
  echo "Файл routing snippet:"
  echo "  /etc/x-ui/warp-generated-routing.json"
  echo
  echo "x-ui DB template apply:"
  echo "  default: disabled"
  echo "  enable only for test: XUI_APPLY_WARP_TEMPLATE=1 sudo bash auto-warp-xui-routing.sh"
  echo "  cleanup old DB routing: XUI_CLEANUP_WARP_TEMPLATE=1 sudo bash auto-warp-xui-routing.sh"
}

main "$@"
