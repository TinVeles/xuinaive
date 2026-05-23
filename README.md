# xuinaive

Unified installer for running 3x-ui, NaiveProxy, Hysteria2, and the NHM Panel on one VPS.

The default command is a dry run. Real installation always requires `--install --yes`.

## What It Installs

- 3x-ui / x-ui-pro with Xray and nginx.
- NHM Panel for NaiveProxy and Hysteria2 management.
- NaiveProxy behind a dedicated Caddy backend.
- Hysteria2 on public UDP `443`.
- Optional Cloudflare WARP local proxy on `127.0.0.1:40000`.
- Optional generated profiles and token-protected subscription files.
- Optional Mieru module in NHM Panel.

The full stack still uses two panels:

- 3x-ui manages Xray inbounds and Xray routing.
- NHM Panel manages NaiveProxy, Hysteria2, Mieru, subscriptions, tuning, diagnostics, and Hy2 bypass/WARP ACL controls.

## Recommended Install

Use this on a fresh VPS:

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

This gives you:

- x-ui and NHM on one VPS.
- 3x-ui profiles on normal inbounds.
- NaiveProxy and Hysteria2 profiles.
- AI-only WARP routing for x-ui.
- Local WARP proxy ready for NHM Panel Hysteria2 routing.
- Final access summary in the terminal and `access-info.txt`.

## Architecture

`--mode all` resolves the public `443/tcp` conflict by giving public TCP `443` to nginx from x-ui-pro:

```text
Internet 443/tcp
  -> nginx stream
     -> x-ui / Xray for x-ui domains and inbounds
     -> 127.0.0.1:9445 for NHM NaiveProxy by SNI

Internet 443/udp
  -> hysteria-server

NHM Panel
  -> 127.0.0.1:3000 internally
  -> 8081 through nginx by default
```

NaiveProxy Caddy does not bind public `443/tcp` in all-in-one mode. It listens on `127.0.0.1:9445`, accepts nginx stream PROXY protocol, and uses the certificate prepared by the installer.

## Modes

```text
all      3x-ui + NHM Panel + NaiveProxy + Hysteria2
xui      only x-ui-pro / 3x-ui planning or install path
naive    compatibility mode routed through the NHM installer
nh       standalone NHM Panel + NaiveProxy + Hysteria2
both     compatibility alias for all
```

Dry run:

```bash
sudo bash install.sh --mode all \
  --xui-domain x.example.com \
  --nh-domain n.example.com \
  --reality-dest r.example.com \
  --nh-email admin@example.com \
  --dry-run
```

Standalone NHM install:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --nh-stack both \
  --nh-access nginx8080 \
  --install \
  --yes
```

Standalone NHM with a panel subdomain:

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

## Install Without WARP

Use this when you want all generated profiles but no Cloudflare WARP service and no WARP routing:

```bash
sudo XUI_ENABLE_WARP_ROUTING=0 \
  XUI_CREATE_WARP=0 \
  AUTO_INSTALL_WARP=0 \
  bash install.sh --mode all \
    --xui-domain xui.example.com \
    --nh-domain naive.example.com \
    --reality-dest reality.example.com \
    --nh-email admin@example.com \
    --generate-profiles \
    --profile-count 15 \
    --profile-prefix auto \
    --install \
    --yes
```

In this mode:

- `install-warp.sh` is not run.
- x-ui WARP routing is not written.
- Legacy `*-warp` inbounds are not created.
- Normal x-ui, NaiveProxy, Hysteria2, and subscription generation still work.

## Existing Certificates

If the NHM/NaiveProxy domain already has a certificate, pass it explicitly:

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

If no certificate paths are provided, all-in-one mode first tries nginx HTTP-01 on port `80`. If that fails, it tries a standalone certbot fallback after checking that port `80` is free. The same certificate is used by Caddy-NH and Hysteria2.

## WARP Routing

`--install-warp` installs Cloudflare WARP in local proxy mode:

```text
SOCKS/HTTP proxy: 127.0.0.1:40000
default outbound tag: warp-cli
```

The default model is AI-only routing:

- OpenAI and ChatGPT domains go through WARP.
- Anthropic and Claude domains go through WARP.
- Gemini, Google AI, Google API/static/auth hosts, YouTube support hosts, and NotebookLM domains go through WARP.
- Everything else stays on the normal direct outbound.

For x-ui, the installer and profile generator write one `warp-cli` SOCKS outbound plus one AI-domain routing rule into the x-ui/Xray template. By default the rule has no `inboundTag`, so later edits to inbound tags or inbound settings in 3x-ui do not break the WARP rule. Generated clients stay on the normal Reality, WS, XHTTP, and Trojan-gRPC inbounds.

For NHM Panel, open `Bypass` and enable `AI through WARP for Hy2`. The panel writes Hysteria2 `outbounds` and ACL rules so matching AI domains use the same local WARP proxy. NaiveProxy cannot do this server-side because Caddy `forward_proxy` has no per-domain outbound ACL; configure NaiveProxy split routing in the client instead.

### Sniffing

Generated preset inbounds get Xray sniffing enabled by default for `http`, `tls`, `quic`, and `fakedns`. This applies to Reality, WS, XHTTP, and Trojan-gRPC. Sniffing lets Xray see the destination domain from HTTP Host, TLS SNI, or QUIC SNI before applying domain routing. Without sniffing, some AI-domain rules can be skipped because Xray only sees an IP.

## Profile Generation

Generate or refresh profiles after installation:

```bash
sudo bash generate-profiles.sh --yes
```

Default output:

```text
x-ui:
  15 standard clients on each preset inbound
  one x-ui subscription subId per client index
  AI-only WARP routing when enabled

NHM:
  15 NaiveProxy profiles
  15 Hysteria2 profiles
  token-protected subscription files
```

Custom count and prefix:

```bash
sudo bash generate-profiles.sh \
  --count 15 \
  --prefix auto \
  --yes
```

## Generate profiles without warp

```bash
sudo XUI_ENABLE_WARP_ROUTING=0 bash generate-profiles.sh --yes
sudo systemctl restart x-ui
```

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
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/auto-01.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/auto-01.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/combined.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/combined.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/sing-box.json
```

The subscription token is generated once and stored root-only:

```bash
sudo cat /etc/nh-panel/subscription-token
```

When NHM Panel is exposed on `8081`, subscription URLs look like:

```text
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/naive.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/hy2.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/all.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/auto-01.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/auto-01.b64
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/combined.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/sing-box.json
```

## Access Info

After install or profile generation:

```bash
sudo bash show-access-info.sh
sudo cat access-info.txt
```

The access summary includes panel URLs, generated credentials, service hints, WARP details when configured, and a profiles section when generated files are present.

## Operations

Status:

```bash
sudo ./status.sh
```

Doctor:

```bash
sudo ./doctor.sh
```

Security hardening dry run:

```bash
sudo bash security-hardening.sh
```

Apply recommended hardening:

```bash
sudo bash security-hardening.sh --apply --yes
```

The recommended profile keeps only SSH, `80/tcp`, `443/tcp`, and `443/udp` open, closes public NHM Panel port `8081/tcp`, installs fail2ban and unattended-upgrades, enables `probe_resistance` in `/etc/caddy-nh/Caddyfile`, and restricts access files to `0600`.

Access NHM Panel through an SSH tunnel after hardening:

```bash
ssh -L 8081:127.0.0.1:8081 root@SERVER_IP
```

Then open:

```text
http://127.0.0.1:8081
```

Allow an extra public port only when needed:

```bash
sudo bash security-hardening.sh --apply --yes --allow-port 8443/tcp
```

Restrict panel access to a static IP/CIDR:

```bash
sudo bash security-hardening.sh --apply --yes \
  --panel-mode allow-ip \
  --allow-panel-from YOUR_IP/32
```

SSH password/root login hardening is opt-in:

```bash
sudo bash security-hardening.sh --apply --yes --ssh-disable-password
```

## Manual WARP Setup

Use this when the stack was installed without WARP and you want to add it later:

```bash
cd /root/unified-proxy-manager

sudo bash install-warp.sh \
  --proxy-port 40000 \
  --outbound-tag warp-cli \
  --yes
```

Check WARP:

```bash
systemctl status warp-svc --no-pager
warp-cli --accept-tos status || warp-cli status
ss -lntp | grep 40000
curl -I --max-time 20 --socks5-hostname 127.0.0.1:40000 https://www.google.com/generate_204
curl --max-time 20 --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

Apply x-ui AI routing through WARP without creating legacy clone inbounds:

```bash
sudo XUI_ENABLE_WARP_ROUTING=1 \
  XUI_CREATE_WARP=0 \
  XUI_CREATE_DIRECT=1 \
  XUI_AUTO_INSTALL_WARP=0 \
  bash generate-profiles.sh \
    --count 15 \
    --prefix auto \
    --warp-port 40000 \
    --warp-outbound-tag warp-cli \
    --yes

sudo systemctl restart x-ui
```

If you explicitly want the old behavior where WARP routing is limited to generated preset inbound tags, add:

```bash
--warp-inbound-tag generated
```

Generate the routing snippet without applying it:

```bash
sudo XUI_ENABLE_WARP_ROUTING=1 \
  XUI_APPLY_WARP_TEMPLATE=0 \
  XUI_AUTO_INSTALL_WARP=0 \
  bash generate-profiles.sh \
    --count 15 \
    --prefix auto \
    --warp-port 40000 \
    --warp-outbound-tag warp-cli \
    --yes

sudo jq . /etc/x-ui/warp-generated-routing.json
```

Disable x-ui WARP routing:

```bash
sudo XUI_ENABLE_WARP_ROUTING=0 \
  XUI_CREATE_WARP=0 \
  XUI_CREATE_DIRECT=1 \
  bash generate-profiles.sh \
    --count 15 \
    --prefix auto \
    --yes

sudo systemctl restart x-ui
```

## Uninstall

Dry run:

```bash
sudo bash uninstall-stack.sh
```

Real removal:

```bash
sudo bash uninstall-stack.sh --apply --yes
```

Remove Cloudflare WARP too:

```bash
sudo bash uninstall-stack.sh --apply --yes --remove-warp
```

The uninstaller stops and disables stack services, backs up removed files under `/opt/unified-proxy-manager/backups/uninstall-*`, removes x-ui/NHM/Caddy-NH/Hysteria stack files, removes stack nginx snippets and sites, cleans stack cron entries, and keeps reusable certificate stores.

## Validation

Useful checks before and after changes:

```bash
bash -n install.sh install-unified.sh install-warp.sh generate-profiles.sh status.sh doctor.sh show-access-info.sh uninstall-stack.sh
bash install.sh --mode all --xui-domain x.example.com --nh-domain n.example.com --reality-dest r.example.com --nh-email a@example.com --dry-run
bash install-warp.sh --help
bash generate-profiles.sh --help
```

On Windows, use a working WSL or Git/MSYS Bash. The real target is Ubuntu 22.04/24.04 or Debian 12.

## Repository Layout

```text
.
+-- components/
|   +-- x-ui-pro/
|   +-- nh-panel/
+-- docs/
|   +-- ARCHITECTURE.md
|   +-- PORTS.md
+-- lib/
|   +-- common.sh
|   +-- warp.sh
|   +-- xui-routing.sh
+-- install.sh
+-- install-unified.sh
+-- install-warp.sh
+-- generate-profiles.sh
+-- show-access-info.sh
+-- status.sh
+-- doctor.sh
+-- security-hardening.sh
+-- uninstall-stack.sh
```

## Safety Notes

- Dry-run mode makes no package, service, firewall, or `/etc` changes.
- Real install mode is guarded by `--install --yes`.
- `install-unified.sh` runs the vendored x-ui-pro installer, which can recreate x-ui and nginx configuration. Use it on a fresh VPS or after backups.
- Installers create backups before real stack writes where practical.
- `--xui-warp-clone` and `XUI_CREATE_WARP=1` still exist for deprecated compatibility, but the supported default is normal profiles plus AI-only server-side WARP routing.
