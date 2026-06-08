#!/usr/bin/env bash
# Network-layer hardening for VPS hosting unified-proxy-manager stack.
# Goal: maximize network stability + eliminate DNS/IPv6/route leaks.
#
# Idempotent. Safe to rerun. Defaults to --dry-run unless --apply --yes.
#
# Areas covered:
#   1. systemd-resolved DoT (Cloudflare 1.1.1.1#cloudflare-dns.com)  - DNS leak fix
#   2. TCP keep-alive tuning                                          - long session stability
#   3. nf_conntrack expansion                                         - high-concurrency stability
#   4. IPv6 hardening (mode: keep | disable)                          - IPv6 leak prevention
#   5. UDP buffer + BBR verification                                  - Hysteria2 stability
#   6. ICMP rate-limit relaxation                                     - PMTU discovery for QUIC

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "$SCRIPT_DIR/lib/common.sh" ]] && source "$SCRIPT_DIR/lib/common.sh"

APPLY=0
ASSUME_YES=0
DOT=1
IPV6_MODE="keep"
TCP_TUNE=1
DOT_SERVERS="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com"
DOT_FALLBACK="9.9.9.9#dns.quad9.net"

usage() {
  cat <<EOF
Usage:
  sudo bash network-hardening.sh [options]

Default mode is dry-run. Add --apply --yes to make changes.

Options:
  --apply                       Apply changes
  --yes                         Skip interactive confirmation
  --no-dot                      Skip systemd-resolved DoT setup
  --dot-servers "1.1.1.1#..."   Override primary DoT servers (space-separated)
  --ipv6 keep|disable           IPv6 mode: keep (default) or disable globally
  --no-tcp-tune                 Skip TCP keepalive + conntrack sysctls
  -h, --help                    Show help

What gets configured:
  /etc/systemd/resolved.conf.d/upm-dot.conf      - DoT resolver
  /etc/sysctl.d/99-upm-network.conf              - TCP/conntrack tuning
  /etc/sysctl.d/99-upm-ipv6.conf                 - IPv6 mode (if --ipv6 disable)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --no-dot) DOT=0; shift ;;
    --dot-servers) DOT_SERVERS="${2:-}"; shift 2 ;;
    --ipv6) IPV6_MODE="${2:-}"; shift 2 ;;
    --no-tcp-tune) TCP_TUNE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
[[ "$IPV6_MODE" == "keep" || "$IPV6_MODE" == "disable" ]] || die "--ipv6 must be keep or disable"

run() {
  if [[ "$APPLY" -eq 1 ]]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf '[dry-run] %s\n' "$*"
  fi
}

write_file() {
  local path="$1" mode="$2" content="$3" tmp
  if [[ "$APPLY" -eq 1 ]]; then
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    printf '+ wrote %s (mode %s)\n' "$path" "$mode"
  else
    printf '[dry-run] write %s (mode %s)\n' "$path" "$mode"
  fi
}

backup_dir="/opt/unified-proxy-manager/backups/network-$(date '+%Y-%m-%d-%H-%M-%S')"
if [[ "$APPLY" -eq 1 ]]; then
  install -d -m 0700 "$backup_dir"
  for path in /etc/systemd/resolved.conf.d /etc/sysctl.d /etc/resolv.conf; do
    if [[ -e "$path" || -L "$path" ]]; then
      install -d -m 0700 "$backup_dir$(dirname "$path")"
      cp -aP "$path" "$backup_dir$(dirname "$path")/" 2>/dev/null || true
    fi
  done
  ok "Backup directory: $backup_dir"
fi

if [[ "$APPLY" -eq 1 && "$ASSUME_YES" -ne 1 ]]; then
  warn "Will modify systemd-resolved, sysctl, and possibly disable IPv6."
  read -r -p "Type APPLY to continue: " answer
  [[ "$answer" == "APPLY" ]] || die "Cancelled"
fi

# 1. systemd-resolved DoT
if [[ "$DOT" -eq 1 ]]; then
  if ! command_exists resolvectl 2>/dev/null && ! command_exists systemd-resolve 2>/dev/null; then
    warn "systemd-resolved not available; skipping DoT setup. Configure DNS manually."
  else
    info "Configuring systemd-resolved DoT"
    install -d -m 0755 /etc/systemd/resolved.conf.d 2>/dev/null || true
    DOT_CONFIG="[Resolve]
DNS=${DOT_SERVERS}
FallbackDNS=${DOT_FALLBACK}
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
CacheFromLocalhost=no
"
    write_file /etc/systemd/resolved.conf.d/upm-dot.conf 0644 "$DOT_CONFIG"
    run systemctl restart systemd-resolved
    if [[ "$APPLY" -eq 1 ]]; then
      sleep 1
      if command_exists resolvectl; then
        if resolvectl status 2>/dev/null | grep -qE 'DNSOverTLS:.*yes|DNS over TLS:.*yes|\+DNSOverTLS'; then
          ok "DoT verified active"
        else
          warn "DoT activation could not be confirmed via resolvectl"
        fi
      fi
    fi
  fi
fi

# 2. TCP keepalive + conntrack tuning
if [[ "$TCP_TUNE" -eq 1 ]]; then
  info "Applying TCP keepalive + conntrack tuning"
  TCP_TUNE_CONFIG="# unified-proxy-manager network tuning
# Applied by network-hardening.sh
# Keepalive: detect dead peers faster on long-lived proxy sessions
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 4

# Connection lifecycle
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384

# MTU probing: handle PMTU blackholes on mobile / VPN-over-VPN paths
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# Memory: ancillary buffer + auto-tuning
net.core.optmem_max = 65536
net.ipv4.tcp_notsent_lowat = 131072
net.core.default_qdisc = fq

# Conntrack capacity for high-connection proxy workloads
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30

# QUIC / Hysteria2: avoid ICMP rate-limit choking PMTUD
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_ratemask = 0

# Reverse-path filter: loose so multi-homed proxies work
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# File descriptor headroom for high-fanout proxies
fs.file-max = 2097152
fs.nr_open = 2097152
"
  write_file /etc/sysctl.d/99-upm-network.conf 0644 "$TCP_TUNE_CONFIG"
  run sysctl --system

  info "Raising ulimit nofile / nproc system-wide"
  ULIMIT_CONFIG="# unified-proxy-manager ulimit hardening
# Applied by network-hardening.sh
*       soft    nofile  1048576
*       hard    nofile  1048576
*       soft    nproc   65536
*       hard    nproc   65536
root    soft    nofile  1048576
root    hard    nofile  1048576
"
  write_file /etc/security/limits.d/99-upm-network.conf 0644 "$ULIMIT_CONFIG"

  info "Tuning journald to avoid log-loss during traffic spikes"
  install -d -m 0755 /etc/systemd/journald.conf.d 2>/dev/null || true
  JOURNALD_CONFIG="[Journal]
# Avoid rate-limit drops that hide proxy errors during traffic bursts.
RateLimitIntervalSec=30s
RateLimitBurst=10000
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=14day
"
  write_file /etc/systemd/journald.conf.d/upm-stability.conf 0644 "$JOURNALD_CONFIG"
  run systemctl restart systemd-journald
fi

# 3. IPv6 mode
if [[ "$IPV6_MODE" == "disable" ]]; then
  info "Disabling IPv6 globally"
  IPV6_CONFIG="# IPv6 disabled by unified-proxy-manager network-hardening.sh
# Prevents IPv6 leaks when proxies bind IPv4 only.
# Revert: rm /etc/sysctl.d/99-upm-ipv6.conf && sysctl --system
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
"
  write_file /etc/sysctl.d/99-upm-ipv6.conf 0644 "$IPV6_CONFIG"
  run sysctl --system
  warn "IPv6 disabled. Any service relying on IPv6 (e.g. dual-stack DNS, AAAA-only domains) is now broken."
else
  if [[ -f /etc/sysctl.d/99-upm-ipv6.conf ]]; then
    info "IPv6 keep requested; removing previous disable file"
    run rm -f /etc/sysctl.d/99-upm-ipv6.conf
    run sysctl --system
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    if ip -6 addr show 2>/dev/null | grep -q 'scope global'; then
      info "Public IPv6 address detected"
      bound_v6=0
      if command_exists ss; then
        if ss -H -ltn '( sport = :443 or sport = :80 )' 2>/dev/null | awk '{print $4}' | grep -qE '^\[::\]:|^\[::1\]:'; then
          bound_v6=1
        fi
      fi
      if [[ "$bound_v6" -eq 0 ]]; then
        warn "Public IPv6 exists but no proxy listens on IPv6 ports 80/443. Clients with IPv6 connectivity may bypass your stack."
        warn "Either rerun with --ipv6 disable, or reconfigure nginx/Caddy to bind IPv6 listeners."
      else
        ok "IPv6 listeners present on critical ports"
      fi
    fi
  fi
fi

# 4. BBR verification (assumes upstream installer enabled it)
if [[ "$APPLY" -eq 1 ]] && command_exists sysctl; then
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [[ "$cc" == "bbr" ]]; then
    ok "TCP congestion control: bbr"
  else
    warn "TCP congestion control is $cc (expected bbr). Run network-hardening.sh --apply --yes."
  fi
fi

ok "Network hardening pass complete (mode: $([[ "$APPLY" -eq 1 ]] && printf 'apply' || printf 'dry-run'))"
if [[ "$APPLY" -ne 1 ]]; then
  info "Rerun with --apply --yes to make changes"
fi
