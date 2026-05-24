# xuinaive

Unified installer for running 3x-ui, NaiveProxy, Hysteria2, and the NHM Panel on one VPS.

The default command is a dry run. Real installation always requires `--install --yes`.

## What It Installs

- 3x-ui / x-ui-pro with Xray and nginx.
- NHM Panel for NaiveProxy and Hysteria2 management.
- NaiveProxy behind a dedicated Caddy backend.
- Hysteria2 on public UDP `443`.
- 15 generated profiles and token-protected subscription files by default.
- Optional Cloudflare WARP local proxy on `127.0.0.1:40000` when `--install-warp` is used.
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
  --install \
  --yes
```

This gives you:

- x-ui and NHM on one VPS.
- 15 generated 3x-ui profiles on normal inbounds.
- 15 generated NaiveProxy profiles.
- 15 generated Hysteria2 profiles.
- No WARP by default.
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

## Install With WARP

Use this when you want the default 15 profiles plus Cloudflare WARP for AI routing:

```bash
sudo bash install.sh --mode all \
    --xui-domain xui.example.com \
    --nh-domain naive.example.com \
    --reality-dest reality.example.com \
    --nh-email admin@example.com \
    --install-warp \
    --profile-count 15 \
    --profile-prefix auto \
    --install \
    --yes
```

In this mode:

- `install-warp.sh` prepares local WARP proxy on `127.0.0.1:40000`.
- x-ui WARP routing snippet is generated for AI domains.
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

WARP is disabled by default. Enable it during install with `--install-warp`.

When enabled, Cloudflare WARP runs in local proxy mode:

```text
SOCKS/HTTP proxy: 127.0.0.1:40000
default outbound tag: warp-cli
```

When WARP is enabled, the routing model is AI-only:

- OpenAI and ChatGPT domains go through WARP.
- Anthropic and Claude domains go through WARP.
- Gemini, Google AI, Google API/static/auth hosts, YouTube support hosts, and NotebookLM domains go through WARP.
- Everything else stays on the normal direct outbound.

For x-ui, WARP mode prepares one `warp-cli` SOCKS outbound and one AI-domain routing snippet. By default it does not write directly into the x-ui routing settings DB, because that path can make 3x-ui inbound edits unstable on some panel versions. Generated clients stay on the normal Reality, WS, XHTTP, and Trojan-gRPC inbounds.

For NHM Panel, open `Bypass` and enable `AI through WARP for Hy2`. The panel writes Hysteria2 `outbounds` and ACL rules so matching AI domains use the same local WARP proxy. NaiveProxy cannot do this server-side because Caddy `forward_proxy` has no per-domain outbound ACL; configure NaiveProxy split routing in the client instead.

### Sniffing

Generated preset inbounds get Xray sniffing enabled by default for `http`, `tls`, `quic`, and `fakedns`. This applies to Reality, WS, XHTTP, and Trojan-gRPC. Sniffing lets Xray see the destination domain from HTTP Host, TLS SNI, or QUIC SNI before applying domain routing. Without sniffing, some AI-domain rules can be skipped because Xray only sees an IP.

## Profile Generation

Generate or refresh profiles after installation:

```bash
sudo bash generate-profiles.sh --yes
```

By default this creates 15 x-ui clients on each selected preset inbound, 15 NaiveProxy profiles, and 15 Hysteria2 profiles. It does not install WARP and does not write WARP routing.

The default supported x-ui line is `2.9.*`. Profile generation writes clients through the classic `inbounds.settings.clients` model used by 3x-ui `2.9.*`.

Default output:

```text
x-ui:
  15 generated clients per selected preset inbound
  one x-ui subscription subId per client index
  no WARP routing unless explicitly enabled

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

Generate profiles with WARP routing later:

```bash
sudo bash generate-profiles.sh \
  --install-warp \
  --yes
sudo systemctl restart x-ui
```

Clean up old WARP template settings if an earlier install wrote them directly into x-ui:

```bash
cd ~/unified-proxy-manager
git pull

sudo bash generate-profiles.sh \
  --xui-only \
  --no-xui-warp-routing \
  --no-auto-install-warp \
  --cleanup-xui-warp-template \
  --yes

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
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/v2rayn.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/v2rayn.b64
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/v2rayn-raw.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/v2rayn-stable.txt
/opt/panel-naive-hy2/subscriptions/SUBSCRIPTION_TOKEN/sing-box.json
```

Combined per-client subscriptions first pull the matching 3x-ui subscription, then normalize visible names from the Reality profile name and append NaiveProxy and Hysteria2 links. The NHM username/password in NaiveProxy and Hysteria2 links is unchanged.

Generated profile names use the Reality client name as the base. For example, if the Reality profile base is `user01`, generated links are named `reality-user01`, `ws-user01`, `xhttp-user01`, `trojan-grpc-user01`, `naive-user01`, and `hy2-user01`.

Refresh combined subscriptions after changing names in 3x-ui:

```bash
sudo bash update-subscriptions.sh --yes
```

This does not edit x-ui clients, NHM users, inbounds, routing, or passwords.

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
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/v2rayn-stable.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/v2rayn.txt
http://SERVER_IP:8081/sub/SUBSCRIPTION_TOKEN/sing-box.json
```

Use `v2rayn-stable.txt` first for v2rayN. It is base64 and excludes newer XHTTP links for older clients. Use `v2rayn.txt` when your v2rayN supports all generated Xray links. `v2rayn-raw.txt` contains the same links as plain text. `combined.txt` includes NaiveProxy and Hysteria2 links too, and some Xray clients reject the whole subscription when they see unsupported `naive+https://` lines.

## Optional x-ui Subscription Domain

The default install does not expose a custom x-ui subscription domain. If you need a dedicated HTTPS subscription URL for x-ui clients, use the separate module:

```bash
sudo bash configure-xui-subscription.sh \
  --domain SUB_DOMAIN \
  --port SUB_PORT \
  --path /SUB_PATH/ \
  --sub-id SUB_ID \
  --yes
```

Do not use the same domain for this subscription endpoint and Reality SNI/serverName. nginx stream routes public `443/tcp` by SNI, so reusing the subscription SNI for Reality sends Reality traffic to the subscription backend.

Full setup notes and placeholder-only examples are in [docs/xui-subscription-domain.md](docs/xui-subscription-domain.md).

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

Apply x-ui AI routing through WARP:

```bash
sudo XUI_ENABLE_WARP_ROUTING=1 \
  XUI_CREATE_DIRECT=1 \
  XUI_AUTO_INSTALL_WARP=0 \
  bash generate-profiles.sh \
    --count 15 \
    --prefix auto \
    --warp-port 40000 \
    --warp-outbound-tag warp-cli \
    --yes

sudo jq . /etc/x-ui/warp-generated-routing.json
sudo systemctl restart x-ui
```

By default this does not edit x-ui routing settings. It only creates clients and writes `/etc/x-ui/warp-generated-routing.json`, so the x-ui UI stays editable. Add the outbound/routing manually in the panel:

```text
outbound tag: warp-cli
protocol: socks
address: 127.0.0.1
port: 40000
```

If you explicitly want routing limited to generated preset inbound tags, add:

```bash
--warp-inbound-tag generated
```

Apply the generated WARP routing directly to the x-ui template database only when you are ready to test that mode:

```bash
sudo XUI_ENABLE_WARP_ROUTING=1 \
  XUI_APPLY_WARP_TEMPLATE=1 \
  XUI_AUTO_INSTALL_WARP=0 \
  bash generate-profiles.sh \
    --count 15 \
    --prefix auto \
    --warp-port 40000 \
    --warp-outbound-tag warp-cli \
    --apply-xui-warp-template \
    --yes
```

Repair an older install where generated WARP settings were already written into x-ui and the panel cannot edit inbounds:

```bash
sudo bash generate-profiles.sh \
  --xui-only \
  --no-xui-warp-routing \
  --no-auto-install-warp \
  --cleanup-xui-warp-template \
  --yes

sudo systemctl restart x-ui
```

Disable x-ui WARP routing:

```bash
sudo XUI_ENABLE_WARP_ROUTING=0 \
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

Uninstall only 3x-ui

```bash
sudo systemctl stop x-ui 2>/dev/null || true
sudo systemctl disable x-ui 2>/dev/null || true

sudo rm -rf /etc/x-ui
sudo rm -rf /usr/local/x-ui
sudo rm -f /etc/systemd/system/x-ui.service
sudo rm -rf /etc/systemd/system/x-ui.service.d

sudo systemctl daemon-reload
```


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
- Generated x-ui profiles use only the normal preset inbounds. WARP is server-side routing through the `warp-cli` outbound, not separate `*-warp` clone inbounds.
