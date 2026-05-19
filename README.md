# xuinaive

Unified installer for all components on one VPS:

- x-ui-pro / 3x-ui / Xray / nginx;
- NHM Panel / NaiveProxy / Caddy backend;
- Hysteria2.

Default `install.sh` mode is safe dry-run. Real install requires explicit `--install --yes`.

## Files

```text
Repository root:
├── .gitignore
├── AUDIT.md
├── components/
├── config.example.env
├── install.sh
├── install-unified.sh
├── install-warp.sh
├── generate-profiles.sh
├── show-access-info.sh
├── status.sh
├── doctor.sh
├── security-hardening.sh
├── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   └── PORTS.md
```

The repository also contains vendored component copies under `components/`:

```text
components/
├── x-ui-pro/
└── nh-panel/
```

## What You Get

- `--mode all`: installs 3x-ui / x-ui-pro plus NHM Panel, NaiveProxy, and Hysteria2 on one VPS.
- nginx from x-ui-pro owns public `443/tcp`.
- NHM Caddy/NaiveProxy runs behind nginx on `127.0.0.1:9445`.
- Hysteria2 uses public `443/udp`.
- NHM Caddy uses a ready certificate/key and accepts nginx stream PROXY protocol on the backend listener.
- Optional Cloudflare WARP local proxy can be installed on `127.0.0.1:40000`.
- Optional Mieru support is disabled by default; add `--with-mieru` only when you want the NHM Panel to expose the Mieru module.
- Optional bulk profile generator can create x-ui, NaiveProxy, and Hysteria2 clients.
- You still get two web panels: 3x-ui for Xray/3x-ui and NHM Panel for NaiveProxy + Hysteria2.

## Quick Start From VPS

One command for real unified install on a fresh VPS:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/TinVeles/xuinaive.git unified-proxy-manager
cd unified-proxy-manager
sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --nh-domain naive.example.com \
  --reality-dest reality.example.com \
  --nh-email admin@example.com \
  --install-warp \
  --generate-profiles \
  --install \
  --yes
```

If you already have a certificate for the NHM/NaiveProxy domain, pass it explicitly:

```bash
sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --nh-domain naive.example.com \
  --reality-dest reality.example.com \
  --nh-email admin@example.com \
  --tls-cert /etc/letsencrypt/live/naive.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/naive.example.com/privkey.pem \
  --install \
  --yes
```

In `--mode all`, the installer does not let Caddy issue its own certificate on `127.0.0.1:9445`. If `--tls-cert` and `--tls-key` are omitted, it first issues the NHM/NaiveProxy certificate through nginx HTTP-01 on port `80`; if that fails, it automatically tries a standalone certbot fallback after stopping nginx/caddy and checking that `80/tcp` is free. It then configures both Caddy and Hysteria2 to use the same cert/key, installs a renewal deploy hook, and stops the install if backend TLS or public nginx stream TLS does not pass `openssl s_client` checks. The NHM Panel is checked on `127.0.0.1:3000`, through local nginx on `127.0.0.1:8081`, and through the server public IP on `8081`; if the last check fails, open `8081/tcp` in the VPS provider firewall/security group.

`--install-warp` installs Cloudflare WARP in local proxy mode after the main stack is installed. It creates a local SOCKS/HTTP proxy on `127.0.0.1:40000` and saves ready 3x-ui/Xray snippets to `/etc/x-ui/warp-xray-snippets.json`. The default routing is split: ChatGPT/OpenAI, Claude/Anthropic, Gemini/Google AI, and NotebookLM domains go through WARP; everything else uses direct routing.

`--with-mieru` exposes the optional Mieru module inside NHM Panel. The default install does not install `mita`, does not show Mieru controls, and keeps the base stack as x-ui + NHM Panel + NaiveProxy + Hysteria2.

By default the x-ui installer creates the preset direct inbounds with one default client on each inbound, plus matching WARP clone inbounds for the same protocols with one WARP client each. This keeps the 3x-ui manual inbound/client editor clean while preserving WARP variants.

`--generate-profiles` additionally creates 4 x-ui WARP-split clients on WARP clone inbounds, 4 NaiveProxy profiles, and 4 Hysteria2 profiles. By default each x-ui client index gets its own `subId`, so `auto-01` contains the WARP variants for client 01, `auto-02` contains the same WARP variant set for client 02, and so on. WARP routing is written into the x-ui template by default: only the configured AI domains use the `warp-cli` outbound, while all unmatched traffic falls back to direct. Client emails stay unique and stable per variant, for example `auto-01-warp-reality` and `auto-01-warp-ws`, so rerunning the generator keeps the same email/UUID/password instead of rotating links. Existing generated direct clients are pruned by default; add `--xui-direct-clients` if you also want direct generated variants. WARP WS/XHTTP/gRPC variants are exported through a separate public port, `8443` by default, while their internal ports remain unique for path routing. Add `--xui-keep-existing` to preserve manual clients, `--xui-inbound-id ID` to target one inbound only, or set `XUI_CREATE_WARP=0` to skip WARP clone inbounds. Use `--profile-count N`, `--profile-prefix NAME`, `--warp-ai-domains "domain:example.com,domain:other.example"`, and `--xui-warp-external-port PORT` to change the defaults.

Dry-run only:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/TinVeles/xuinaive.git unified-proxy-manager
cd unified-proxy-manager
sudo bash install.sh
```

## Dry-run commands

Interactive mode:

```bash
sudo bash install.sh
```

The script will ask for:

- mode: `xui`, `naive`, `all`, `both`, or `nh`;
- x-ui domain when needed;
- NaiveProxy domain when needed;
- REALITY destination domain when needed;
- email for future NaiveProxy/Caddy TLS planning.

Only x-ui-pro plan:

```bash
sudo bash install.sh --mode xui --xui-domain x.example.com --reality-dest r.example.com --dry-run
```

Only NaiveProxy plan:

```bash
sudo bash install.sh --mode naive --naive-domain n.example.com --dry-run
```

All components plan:

```bash
sudo bash install.sh --mode all \
  --xui-domain x.example.com \
  --nh-domain n.example.com \
  --reality-dest r.example.com \
  --nh-email admin@example.com \
  --dry-run
```

Standalone NHM Panel plan:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --dry-run
```

Real NHM Panel install:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --nh-stack both \
  --nh-access nginx8080 \
  --install \
  --yes
```

With a separate HTTPS panel subdomain:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --nh-access subdomain \
  --panel-domain panel.example.com \
  --panel-email admin@example.com \
  --install \
  --yes
```

Status:

```bash
sudo ./status.sh
```

Copy-friendly access info after installation:

```bash
sudo cat ./access-info.txt
sudo bash ./show-access-info.sh
```

Doctor:

```bash
sudo ./doctor.sh
```

Security hardening dry-run:

```bash
sudo bash security-hardening.sh
```

Apply the recommended profile:

```bash
sudo bash security-hardening.sh --apply --yes
```

The recommended profile keeps only SSH, `80/tcp`, `443/tcp`, and `443/udp` open, closes the NHM Panel port `8081/tcp` publicly, installs fail2ban and unattended-upgrades, enables `probe_resistance` in `/etc/caddy-nh/Caddyfile`, and restricts access files to `0600`. After that, access the NHM Panel through an SSH tunnel:

```bash
ssh -L 8081:127.0.0.1:8081 root@SERVER_IP
```

Then open:

```text
http://127.0.0.1:8081
```

If you intentionally need an extra public inbound port, keep it open explicitly:

```bash
sudo bash security-hardening.sh --apply --yes --allow-port 8443/tcp
```

To allow the panel only from your current static IP/CIDR:

```bash
sudo bash security-hardening.sh --apply --yes \
  --panel-mode allow-ip \
  --allow-panel-from YOUR_IP/32
```

SSH password/root login hardening is opt-in because it can lock you out if SSH keys or a sudo user are not ready:

```bash
sudo bash security-hardening.sh --apply --yes --ssh-disable-password
```

## Optional WARP

Standalone WARP install:

```bash
sudo bash install-warp.sh --yes
```

Custom tags/ports for 3x-ui routing:

```bash
sudo bash install-warp.sh \
  --proxy-port 40000 \
  --outbound-tag warp-cli \
  --inbound-tag inbound-443 \
  --route-port 443 \
  --yes
```

The script installs `cloudflare-warp`, registers the client, switches it to local proxy mode, connects WARP, checks the local proxy, and writes:

```text
/etc/x-ui/warp-xray-snippets.json
```

Use those values in 3x-ui/Xray:

```text
Outbound:
  Protocol: socks
  Tag:      warp-cli
  Address:  127.0.0.1
  Port:     40000

Routing:
  Inbound tags: inbound-443
  Domains:      openai.com/chatgpt.com/anthropic.com/claude.ai/gemini.google.com/notebooklm.google
  Outbound:     warp-cli
```

Check WARP:

```bash
warp-cli --accept-tos status
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

## Bulk Profiles

Create the default profile set after installation:

```bash
sudo bash generate-profiles.sh --yes
```

This creates:

```text
x-ui:
  4 WARP-split clients on WARP clone inbounds
  4 x-ui subscription subIds, one per client index
  AI-only WARP routing and direct fallback

NHM:
  4 NaiveProxy profiles
  4 Hysteria2 profiles
```

The script backs up `/etc/x-ui/x-ui.db`, NHM config, Caddyfile, and Hysteria config before writing. x-ui profiles use grouped `subId` values like `auto-01` and stable emails like `auto-01-warp-reality`; the same `subId` is reused across all WARP clone inbounds for that client index. WARP clone inbounds get unique internal paths/ports and a routing rule by Xray `inboundTag` plus AI domain list to outbound `warp-cli`; unmatched domains use the first `direct` outbound. WARP WS/XHTTP/gRPC subscription links use the common public WARP port `8443` by default, and nginx routes those path-based requests to the matching internal inbound. Reality WARP clone still uses its own public port, usually base port + 10000, because Reality cannot share a single public port by path. The VPS firewall/security group must allow the WARP public port and any Reality WARP port you import. NHM generated subscriptions contain exactly `COUNT` NaiveProxy links and `COUNT` Hysteria2 links for the selected prefix.

Generated reports:

```text
/etc/x-ui/generated-clients.txt
/opt/panel-naive-hy2/generated-profiles.txt
```

NHM subscription files:

```text
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/naive.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/hy2.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/all.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/naive.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/hy2.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/all.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/sing-box.json
```

The token is generated once and stored root-only:

```bash
sudo cat /etc/nh-panel/subscription-token
```

When the NHM Panel is exposed by nginx on `8081`, the generator also adds token-protected `/sub/` URLs:

```text
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/naive.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/hy2.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/all.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/sing-box.json
```

Custom count/prefix:

```bash
sudo bash generate-profiles.sh \
  --count 4 \
  --prefix auto \
  --yes
```

## What install.sh checks

- root or non-root execution warning;
- OS support: Ubuntu 22.04, Ubuntu 24.04, Debian 12;
- required commands: `curl`, `wget`, `git`, `systemctl`;
- vendored component presence;
- service states for `x-ui`, `nginx`, `caddy-nh`, `ufw`;
- service states for `hysteria-server` and `panel-naive-hy2` when present;
- listeners on `80`, `443`, `2053`, `8443`, `9443`;
- DNS A records for provided domains against current public IPv4;
- NHM backend/public TLS checks and SNI backend layout for `all` mode.
- NHM Panel HTTP checks on backend `3000`, nginx proxy `8081`, and public `SERVER_IP:8081`.

## Important

The audit found that upstream `x-ui-pro.sh` performs destructive actions early: it removes x-ui/nginx paths and kills listeners on `80/443`. This safe version intentionally does not run it.

## Current Safety Status

`install.sh` is intentionally a planner. It is safe to run on a VPS because it only reads system state:

- no package installation;
- no writes to `/etc`;
- no service start/stop/restart;
- no firewall changes;
- no upstream installer execution.

## Real Unified Installer

Direct all-in-one installer command through `install.sh`:

```bash
sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --nh-domain naive.example.com \
  --reality-dest reality.example.com \
  --nh-email admin@example.com \
  --install \
  --yes
```

This installer uses one public `443` owner:

- x-ui-pro/nginx listens on public `443`;
- NHM NaiveProxy/Caddy listens on `127.0.0.1:9445`;
- nginx stream routes the NHM/NaiveProxy domain by SNI to `127.0.0.1:9445` and Caddy accepts the stream PROXY protocol before TLS;
- Hysteria2 listens on public `443/udp`;
- NHM Panel is available through nginx on `8081` by default.

Warning: `install-unified.sh` runs the vendored x-ui-pro installer, which is destructive like upstream. Use it only on a fresh VPS or after backups.

## Legacy / Standalone Modes

`--mode nh` still exists for a standalone NHM Panel install without 3x-ui. For one-command 3x-ui + NHM, use `--mode all`.
