#!/usr/bin/env bash

UPM_DEFAULT_AI_DOMAINS="domain:openai.com,domain:chatgpt.com,domain:oaistatic.com,domain:oaiusercontent.com,domain:anthropic.com,domain:claude.ai,domain:gemini.google.com,domain:aistudio.google.com,domain:ai.google.dev,domain:generativelanguage.googleapis.com,domain:aiplatform.googleapis.com,domain:googleapis.com,domain:gstatic.com,domain:googleusercontent.com,domain:ggpht.com,domain:clients6.google.com,domain:accounts.google.com,domain:apis.google.com,domain:ogs.google.com,domain:www.google.com,domain:play.google.com,domain:withgoogle.com,domain:youtube.com,domain:ytimg.com,domain:notebooklm.google.com,domain:notebooklm.google"

warp_domains_json() {
  local domains="${1:-$UPM_DEFAULT_AI_DOMAINS}"
  printf '%s\n' "$domains" \
    | tr ',' '\n' \
    | jq -Rsc 'split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique'
}

warp_inbound_tags_json() {
  local inbound_tags="${1:-all}"
  if [[ -z "$inbound_tags" || "$inbound_tags" == "all" || "$inbound_tags" == "*" ]]; then
    printf 'null\n'
  else
    printf '%s\n' "$inbound_tags" \
      | tr ',' '\n' \
      | jq -Rsc 'split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)) | unique'
  fi
}

warp_write_xray_snippet() {
  local snippet_file="$1" outbound_tag="$2" host="$3" port="$4" domains="$5" inbound_tags="${6:-all}"
  local domains_json inbound_tags_json
  domains_json="$(warp_domains_json "$domains")"
  inbound_tags_json="$(warp_inbound_tags_json "$inbound_tags")"
  mkdir -p "$(dirname "$snippet_file")"
  jq -cn \
    --arg tag "$outbound_tag" \
    --arg host "$host" \
    --argjson port "$port" \
    --argjson inboundTags "$inbound_tags_json" \
    --argjson domains "$domains_json" \
    '{
      outbound: {tag:$tag, protocol:"socks", settings:{servers:[{address:$host, port:$port, users:[]}]}},
      routingRule: ({type:"field", domain:$domains, outboundTag:$tag} + (if $inboundTags == null then {} else {inboundTag:$inboundTags} end))
    }' > "$snippet_file"
}

warp_local_proxy_ready() {
  local host="${1:-${WARP_PROXY_HOST:-127.0.0.1}}" port="${2:-${WARP_PROXY_PORT:-40000}}"
  local status_text trace_output
  command_exists warp-cli || return 1
  status_text="$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || true)"
  grep -qi "disconnected" <<<"$status_text" && return 1
  grep -qi "connected" <<<"$status_text" || return 1
  if command_exists curl; then
    trace_output="$(curl -fsS --max-time 20 --socks5-hostname "${host}:${port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    grep -Eqi '^warp=(on|plus)$' <<<"$trace_output"
    return
  fi
  if command_exists ss; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    return
  fi
  return 1
}

ensure_warp_local_proxy() {
  local script_dir="${1:-${SCRIPT_DIR:-.}}" should_require="${2:-1}"
  [[ "$should_require" == "1" ]] || return 0
  if warp_local_proxy_ready "${WARP_PROXY_HOST:-127.0.0.1}" "${WARP_PROXY_PORT:-40000}"; then
    upm_log_ok "WARP local proxy is ready at ${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000}"
    return 0
  fi
  if [[ "${XUI_AUTO_INSTALL_WARP:-${AUTO_INSTALL_WARP:-1}}" != "1" ]]; then
    upm_log_warn "WARP routing is enabled, but WARP local proxy is not ready at ${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000}"
    upm_log_warn "Run install-warp.sh or disable WARP routing before generating profiles"
    return 0
  fi
  [[ "${WARP_PROXY_HOST:-127.0.0.1}" == "127.0.0.1" || "${WARP_PROXY_HOST:-127.0.0.1}" == "localhost" ]] || upm_die "Auto WARP install supports only local WARP_PROXY_HOST, got: ${WARP_PROXY_HOST}"
  [[ -f "$script_dir/install-warp.sh" ]] || upm_die "WARP installer not found: $script_dir/install-warp.sh"
  upm_log_info "WARP local proxy is missing; installing Cloudflare WARP automatically"
  bash "$script_dir/install-warp.sh" \
    --proxy-port "${WARP_PROXY_PORT:-40000}" \
    --outbound-tag "${WARP_OUTBOUND_TAG:-warp-cli}" \
    --warp-ai-domains "${WARP_AI_DOMAINS:-$UPM_DEFAULT_AI_DOMAINS}" \
    --yes
  warp_local_proxy_ready "${WARP_PROXY_HOST:-127.0.0.1}" "${WARP_PROXY_PORT:-40000}" || upm_die "WARP install finished, but local proxy is not ready at ${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000}"
  upm_log_ok "WARP local proxy is ready at ${WARP_PROXY_HOST:-127.0.0.1}:${WARP_PROXY_PORT:-40000}"
}
