#!/bin/bash
# ═══════════════════════════════════════════════════════
#  Сетевой тюнинг (BBR + UDP buffers) — NHM Panel
#  Вызывается из панели кнопкой "Применить оптимизации"
# ═══════════════════════════════════════════════════════

set -uo pipefail

cat > /etc/sysctl.d/99-nh-tune.conf << 'SYSCTLEOF'
# NHM Panel — Naive (TCP) + Hy2 (UDP) tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# UDP buffers for Hysteria2 and high-latency links
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000

# TCP stability for long-lived proxy sessions
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.somaxconn=8192
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535

# Connection tracking
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# Keep PMTUD working and avoid strict reverse-path drops on routed VPS setups
net.ipv4.ip_no_pmtu_disc=0
net.ipv4.icmp_echo_ignore_all=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2

# IPv6
net.ipv6.conf.all.disable_ipv6=0
SYSCTLEOF

apply_log="$(mktemp)"
if sysctl --system >"$apply_log" 2>&1; then
  APPLY_OK=1
else
  APPLY_OK=0
fi
if sysctl -p /etc/sysctl.d/99-nh-tune.conf >>"$apply_log" 2>&1; then
  DIRECT_APPLY_OK=1
else
  DIRECT_APPLY_OK=0
fi

# Проверяем фактически примененные значения.
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")
KA=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo "unknown")
CT=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "unknown")

RMEM_NUM=0
if [[ "$RMEM" =~ ^[0-9]+$ ]]; then
  RMEM_NUM="$RMEM"
fi

if [[ "$CC" == "bbr" && "$QDISC" == "fq" && "$RMEM_NUM" -ge 16777216 ]]; then
  echo "OK: sysctl applied"
  if [[ "$APPLY_OK" != "1" || "$DIRECT_APPLY_OK" != "1" ]]; then
    echo "WARN: some optional sysctl keys were not accepted by this kernel"
    sed -n '1,20p' "$apply_log" 2>/dev/null || true
  fi

  echo "congestion_control=${CC}"
  echo "qdisc=${QDISC}"
  echo "rmem_max=${RMEM}"
  echo "tcp_keepalive_time=${KA}"
  echo "conntrack_max=${CT}"
  rm -f "$apply_log"
  exit 0
else
  echo "ERROR: sysctl failed"
  sed -n '1,80p' "$apply_log" 2>/dev/null || true
  rm -f "$apply_log"
  exit 1
fi
