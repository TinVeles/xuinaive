# Security Notes for unified-proxy-manager

## Network stability and leak prevention

### `network-hardening.sh`

One-shot opt-in script that applies all network-layer hardening at once.
Default mode is dry-run; pass `--apply --yes` to make changes.

```sh
sudo bash network-hardening.sh                     # dry-run preview
sudo bash network-hardening.sh --apply --yes       # apply everything
sudo bash network-hardening.sh --apply --yes --ipv6 disable   # also kill IPv6
```

Applied configuration:

| File | Purpose |
|------|---------|
| `/etc/systemd/resolved.conf.d/upm-dot.conf` | systemd-resolved DoT via Cloudflare 1.1.1.1#cloudflare-dns.com + Quad9 fallback |
| `/etc/sysctl.d/99-upm-network.conf` | TCP keepalive 120s, conntrack 1M entries, ICMP relax for QUIC PMTUD, rp_filter loose |
| `/etc/sysctl.d/99-upm-ipv6.conf` | IPv6 disable (only if `--ipv6 disable`) |

The script verifies BBR is active and warns if a public IPv6 address exists
without IPv6 listeners — a classic leak vector when proxies bind IPv4 only.

Recommended install order:

```
1. install.sh / install-unified.sh       (install stack)
2. network-hardening.sh --apply --yes    (DNS + sysctl + IPv6 + journald + ulimit)
3. service-stability.sh --apply --yes    (systemd dropins: Restart/LimitNOFILE/OOM)
4. install-warp-watchdog.sh --yes        (if WARP enabled, recover from silent hangs)
5. security-hardening.sh --apply --yes   (fail2ban, ssh, UFW)
6. doctor.sh                             (verify no leaks / unstable settings)
```

### `service-stability.sh`

Writes drop-in `/etc/systemd/system/<svc>.service.d/upm-stability.conf` to:
`x-ui`, `nginx`, `caddy-nh`, `hysteria-server`, `panel-naive-hy2`, `warp-svc`.

| Setting | Value | Why |
|---------|-------|-----|
| `Restart` | `on-failure` | auto-recovery without infinite loops on bad config |
| `RestartSec` | `10s` | back off briefly before retry |
| `StartLimitIntervalSec` | `300s` | within 5 min window |
| `StartLimitBurst` | `10` | max 10 restarts before systemd gives up |
| `LimitNOFILE` | `1048576` | high-fanout proxies need many fds |
| `LimitNPROC` | `65536` | room for per-connection threads (Node.js / Caddy) |
| `TasksMax` | `infinity` | systemd default 512 is too low for proxies |
| `OOMScoreAdjust` | `-500` | proxy daemons less likely to be killed under memory pressure |
| `TimeoutStopSec` | `15s` | allow graceful drain of active connections |

Drop-ins are preserved across upstream unit-file updates. Remove with
`service-stability.sh --remove --yes`.

### `install-warp-watchdog.sh`

Cloudflare WARP daemon (`warp-svc`) has a known silent-hang failure mode:
systemctl reports active, but the SOCKS endpoint on `127.0.0.1:40000` stops
responding. Restart manually is the only fix.

The watchdog installs a systemd timer that probes the SOCKS endpoint every
60 seconds via `curl --socks5-hostname`. On two consecutive failures it
restarts `warp-svc` and reconnects via `warp-cli connect`. State persists at
`/var/lib/upm-warp-watchdog.state`.

```sh
sudo bash install-warp-watchdog.sh --yes
systemctl list-timers upm-warp-watchdog.timer
journalctl -u upm-warp-watchdog -n 50
```

Uninstall: `sudo bash install-warp-watchdog.sh --uninstall --yes`.

### Extended sysctl tuning (network-hardening.sh)

Beyond the leak-prevention defaults documented above, the script applies:

| Sysctl | Value | Effect |
|--------|-------|--------|
| `net.ipv4.tcp_mtu_probing` | `1` | recover from PMTU blackholes (mobile / VPN-over-VPN) |
| `net.ipv4.tcp_base_mss` | `1024` | conservative MSS floor for probing |
| `net.core.optmem_max` | `65536` | larger ancillary buffer for socket options |
| `net.ipv4.tcp_notsent_lowat` | `131072` | bound unsent buffer per socket |
| `net.netfilter.nf_conntrack_buckets` | `262144` | hash size for 1M conntrack entries |
| `nf_conntrack_tcp_timeout_close_wait` | `30s` | quickly release half-closed proxy sessions |
| `nf_conntrack_tcp_timeout_fin_wait` | `30s` | free FIN-WAIT slots faster |
| `fs.file-max` / `fs.nr_open` | `2097152` | system-wide fd ceiling |

Plus `/etc/security/limits.d/99-upm-network.conf` raises per-process
`nofile` to 1M and `nproc` to 64k (matches systemd dropins).

Plus `/etc/systemd/journald.conf.d/upm-stability.conf` raises the journald
rate-limit to `10000 messages / 30s` and caps storage at 500MB so log floods
during traffic spikes don't suppress actual error events.

### DNS-over-TLS for system queries

Without DoT, the install process leaks the VPS↔domain association into the
upstream resolver's logs (typically the VPS provider). `network-hardening.sh`
configures systemd-resolved with DoT mode:

```
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
FallbackDNS=9.9.9.9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=allow-downgrade
```

Verify after applying:

```sh
resolvectl status | grep -E 'DNS|DNSOverTLS'
# expect: +DNSOverTLS=yes  or  DNS over TLS: yes
```

Pre-set `PUBLIC_IP` in `config.env` before running installers to also avoid
calls to `ipv4.icanhazip.com` / `api.ipify.org`:

```sh
echo 'PUBLIC_IP="203.0.113.10"' >> config.env
```

### IPv6 leak prevention

If the VPS has a public IPv6 address but your proxy listeners bind IPv4 only
(default for most x-ui REALITY/Naive setups), IPv6-capable clients may bypass
the stack entirely. `doctor.sh` reports the situation, and
`network-hardening.sh --ipv6 disable` blocks the leak vector.

Alternative: leave IPv6 enabled and reconfigure nginx/Caddy/Hysteria2 to bind
both stacks (`listen [::]:443` etc). Either approach is acceptable.

### WARP kill-switch (#11 extension)

Xray routing rules use first-match semantics. AI-domain requests are matched
by the WARP routing rule (added by `lib/xui-routing.sh` and *prepended* to the
rule list since unified-proxy-manager v2). When the WARP local proxy
(`127.0.0.1:40000`) is unreachable:

1. Xray attempts to connect to the WARP socks outbound.
2. Socks handshake fails.
3. Xray drops the client request with a proxy error.

Xray does NOT fall back to the `direct` outbound on socks failure, so AI
traffic cannot leak to the ISP when WARP is down. This is the implicit
kill-switch behavior — DO NOT add a fallback rule (`outboundTag: direct`) for
AI domains.

DNS for AI domains is routed through DoH (`https://1.1.1.1/dns-query`) at the
Xray DNS layer (`lib/xui-routing.sh` and `lib/warp.sh`). If WARP socks fails,
the DoH connection also fails (it travels through the same socks). No DNS
leak.

To verify the kill-switch in production:

```sh
systemctl stop warp-svc
curl -i --max-time 10 --connect-timeout 5 \
  -x socks5h://127.0.0.1:40000 https://api.openai.com  # expect: fails immediately
systemctl start warp-svc
```

### Long-session stability

The TCP keepalive defaults installed by `network-hardening.sh`:

```
net.ipv4.tcp_keepalive_time = 120     # send first probe after 120s idle
net.ipv4.tcp_keepalive_intvl = 30     # 30s between probes
net.ipv4.tcp_keepalive_probes = 4     # 4 missed probes before drop
```

Reaches "this connection is dead" verdict in ~240s instead of the kernel
default ~2h. This prevents NAT-rebind ghost connections that pile up on
the proxy and starve conntrack slots over time.

### Connection tracking capacity

`nf_conntrack_max=1048576` is applied (matches upstream nh-panel tuning).
Combined with `tcp_keepalive_time=120` this supports a sustained ~10k
active proxy sessions without conntrack pressure.

Monitor:

```sh
cat /proc/sys/net/netfilter/nf_conntrack_count   # current
cat /proc/sys/net/netfilter/nf_conntrack_max     # ceiling
```

If `count / max > 0.7`, raise `nf_conntrack_max` further.

## Network-level metadata leaks

### Public-IP probing during install (#10)

Install scripts query third-party endpoints to discover the VPS public IP:

```
curl https://ipv4.icanhazip.com
curl https://api.ipify.org
```

Cloudflare (which fronts both services) sees the request originate from your
VPS. If the install happens before DNS records point to the VPS, this
associates the IP with the imminent panel/proxy domains earlier than
necessary.

**Mitigation:** Pre-set `PUBLIC_IP` in `config.env` before running installers.
The scripts honour explicit overrides and skip the probe.

```sh
echo 'PUBLIC_IP="203.0.113.10"' >> config.env
```

### DNS probing during install (#10)

`doctor.sh` and `show-access-info.sh` use the system resolver to verify
A/AAAA records for the configured domains. On most VPS providers this hits a
caching resolver controlled by the hoster, leaking the VPS-domain mapping into
their logs.

**Mitigation (one-time, OS-level):** point the host resolver at a privacy DNS
provider before running scripts:

```sh
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/upm.conf <<'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
systemctl restart systemd-resolved
```

This routes ALL system DNS through Cloudflare DoT, including the install
script's `dig`/`getent` queries.

### Server-side WARP DNS routing (#11)

When `--install-warp` enables Cloudflare WARP for AI-domain routing, the Xray
DNS configuration generated by `lib/warp.sh:warp_write_xray_snippet` now
forces DoH (DNS over HTTPS) via `https://1.1.1.1/dns-query` for those
domains. AI domain queries no longer leak to the system resolver, which would
otherwise expose them to the VPS hoster's logs.

Existing installs need to regenerate the snippet:

```sh
bash install-warp.sh --proxy-port 40000 --outbound-tag warp-cli --yes
```

or re-run `generate-profiles.sh` once. The new DNS block is applied
automatically the next time Xray reloads its template config.

Client-side DNS resolution is outside the scope of the server. If a user's
device resolves `api.openai.com` locally before connecting, that query still
leaks at the client level. Recommend clients use the bundled Xray sniffing
flow (configure inbound `sniffing.enabled=true`) so domain detection happens
inside the tunnel.

## Supply-chain integrity

### Vendored upstream binaries (#1)

`components/x-ui-pro/x-ui-pro.sh` (vendored from MHSanaei/3x-ui) downloads:

* `x-ui-linux-<arch>.tar.gz` (3x-ui release)
* `x-ui.sh` (main-branch raw)
* `x-ui.rc` (main-branch raw, Alpine only)
* `sub2sing-box_<ver>_linux_<arch>.tar.gz`

These have no SHA256 verification in the upstream script. The unified
installers DO NOT call the vendored script directly. Instead they run
`components/x-ui-pro/verify-upstream-binaries.sh` which:

1. Downloads each artifact to `/var/tmp/upm-x-ui-prefetch/`.
2. Verifies SHA256 against `upstream-pins.env` (STRICT) or seeds a TOFU
   lockfile (`upstream-pins.lock`) on first install.
3. Emits a patched runtime copy of `x-ui-pro.sh` (in the staging dir) whose
   `wget` calls are replaced with `cp` from the verified staging area.

To promote TOFU to STRICT:

```sh
bash components/x-ui-pro/verify-upstream-binaries.sh --print-current \
  > components/x-ui-pro/upstream-pins.env
```

Inspect the values, commit, and future installs will refuse mismatched
upstream artifacts.

## Panel exposure

By default `PANEL_ACCESS="ssh-tunnel"`: NHM Panel binds to `127.0.0.1:3000`
only; the public port `8081` is closed (`ufw deny 8081/tcp`). Reach the
panel by tunnelling from your workstation:

```sh
ssh -L 8081:127.0.0.1:3000 root@SERVER_IP
# then open http://localhost:8081
```

To expose publicly (NOT recommended), pass `--panel-access nginx8080` to
`install-unified.sh`. In that mode the panel serves over HTTP on port 8081
and subscription tokens travel in plaintext. Use only behind a reverse proxy
or VPN, never as-is.

For HTTPS-accessible subscription URLs without exposing the full panel, run
`configure-nh-subscription.sh --domain sub.example.com --yes` after install.
This stands up an nginx HTTPS site that exposes only `/sub/<TOKEN>/*` via
SNI routing on the existing public 443 listener, with rate limiting.

## Secrets in stdout

`show-access-info.sh` and other scripts print panel credentials to stdout for
operator convenience. This text ends up in:

* tmux scrollback,
* `script(1)` typescript,
* `journalctl` (when run via systemd),
* SSH client terminal recording (PuTTY logging, iTerm2 saved sessions).

Pass `--redact` or set `UPM_REDACT_SECRETS=1` to mask passwords/tokens to
`fo****ar` before printing. Full creds remain in
`/opt/unified-proxy-manager/access-info.txt` (mode 0600, root-only).

## Destructive operations

Real installers (`install.sh --install`, `install-unified.sh`) invoke the
vendored x-ui-pro script which performs:

* `systemctl stop x-ui`
* `rm -rf /usr/local/x-ui /etc/x-ui`
* `fuser -k 80/tcp 443/tcp`

Before this runs, `confirm_destructive` prompts for `Type DESTROY`. Pass
`--allow-destroy-existing` (or env `UPM_ALLOW_DESTROY_EXISTING=1`) to skip
the prompt in CI/automation. `--yes` alone does NOT skip this prompt.

## Firewall lockout protection

`security-hardening.sh --apply --yes` resets UFW. Before reset it:

1. Refuses if no process is listening on `--ssh-port`.
2. Warns if your SSH session arrived on a different port than `--ssh-port`
   (prompts `LOCKOUT-RISK` confirmation unless `--yes`).
3. Arms a background "timebomb" that resets UFW to allow SSH again in
   `UPM_UFW_TIMEBOMB_SECONDS` (default 600s). Disarms automatically on
   successful completion.

If you're locked out, wait ~10 minutes for the timebomb to restore SSH.
