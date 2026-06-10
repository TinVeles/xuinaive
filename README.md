# xuinaive

Unified installer for running 3x-ui plus RIXXX Panel with NaiveProxy and Mieru on one VPS.

The default command is a dry run. Real installation always requires `--install --yes`.

## What It Installs

- 3x-ui / x-ui-pro with Xray and nginx.
- RIXXX Panel for NaiveProxy and Mieru management.
- NaiveProxy behind a dedicated Caddy backend.
- Mieru on its own public TCP/UDP port range.
- Generated 3x-ui profiles by default.
- Optional Cloudflare WARP local proxy on `127.0.0.1:40000` when `--install-warp` is used.

The full stack still uses two panels:

- 3x-ui manages Xray inbounds and Xray routing.
- RIXXX Panel manages NaiveProxy, Mieru users, subscriptions, tuning, and diagnostics.

## Recommended Install

Use this on a fresh VPS:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/TinVeles/xuinaive.git unified-proxy-manager
cd unified-proxy-manager

sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --rixxx-domain naive.example.com \
  --reality-dest reality.example.com \
  --rixxx-email admin@example.com \
  --install \
  --yes
```

The default panel line is the current upstream 3x-ui v3 release, resolved at
install time from `MHSanaei/3x-ui` and validated as `v3.3.0` or newer. SQLite is
selected explicitly. The default inbound set is the stable x-ui-pro-like core:
one VLESS TCP REALITY, one VLESS WS, one VLESS XHTTP, and one Trojan gRPC.

If you explicitly want the larger experimental preset mix, add
`--xui-extended-presets`:

```bash
sudo bash install.sh --mode all \
  --xui-extended-presets \
  --xui-domain xui.example.com \
  --rixxx-domain naive.example.com \
  --reality-dest reality.example.com \
  --rixxx-email admin@example.com \
  --install \
  --yes
```

For an x-ui-only fresh VPS, choose one installer explicitly:

```bash
# Existing 2.9.4 schema: clients live inside each inbound.
sudo bash install-xui-legacy.sh \
  --xui-domain x.example.com \
  --reality-dest r.example.com \
  --install \
  --yes

# Current upstream v3 release: resolved dynamically during install.
# SQLite is selected explicitly; one client entity is attached to many inbounds.
sudo bash install-xui-latest.sh \
  --xui-domain x.example.com \
  --reality-dest r.example.com \
  --install \
  --yes
```

`install-xui-latest.sh` does not pin a release number. It resolves the current
official GitHub release at install time, verifies downloaded artifacts, writes
`XUI_DB_TYPE=sqlite` to `/etc/default/x-ui`, and runs `generate-xui-v3.sh`.
Use latest mode on a fresh VPS or after a backup: the x-ui installer recreates
the existing x-ui and nginx state. In `--mode all`, latest mode uses
`generate-xui-v3.sh` for the 3x-ui client/entity schema and RIXXX manages
NaiveProxy/Mieru users through its own panel.

This gives you:

- x-ui and RIXXX on one VPS.
- 15 generated 3x-ui profiles attached to the stable core inbounds.
- NaiveProxy and Mieru users managed in RIXXX Panel.
- No WARP by default.
- Final access summary in the terminal and `access-info.txt`.

## Architecture

`--mode all` resolves the public `443/tcp` conflict by giving public TCP `443` to nginx from x-ui-pro:

```text
Internet 443/tcp
  -> nginx stream
     -> x-ui / Xray REALITY backends by decoy SNI
     -> x-ui HTTPS vhost and websocket path proxy by x-ui domain
     -> 127.0.0.1:9445 for RIXXX NaiveProxy by SNI

Internet 2012/tcp and configured Mieru range
  -> mita / Mieru

RIXXX Panel
  -> 127.0.0.1:3000 internally
  -> 8081 through nginx by default
```

NaiveProxy Caddy does not bind public `443/tcp` in all-in-one mode. It listens on `127.0.0.1:9445`, accepts nginx stream PROXY protocol, and uses the certificate prepared by the installer.

## Modes

```text
all      3x-ui + RIXXX Panel + NaiveProxy + Mieru
xui      only x-ui-pro / 3x-ui planning or install path
naive    compatibility mode routed through the RIXXX installer
nh       standalone RIXXX Panel + NaiveProxy + Mieru
both     compatibility alias for all
```

Dry run:

```bash
sudo bash install.sh --mode all \
  --xui-domain x.example.com \
  --rixxx-domain n.example.com \
  --reality-dest r.example.com \
  --rixxx-email admin@example.com \
  --dry-run
```

Standalone RIXXX install:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --panel-access nginx8080 \
  --install \
  --yes
```

Standalone RIXXX with a panel subdomain:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --panel-access subdomain \
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
    --rixxx-domain naive.example.com \
    --reality-dest reality.example.com \
    --rixxx-email admin@example.com \
    --install-warp \
    --profile-count 15 \
    --profile-prefix auto \
    --install \
    --yes
```

In this mode:

- `install-warp.sh` prepares local WARP proxy on `127.0.0.1:40000`.
- x-ui WARP routing snippet is generated for AI domains.
- Normal x-ui generation still works; NaiveProxy and Mieru users are managed in RIXXX Panel.

## Existing Certificates

If the RIXXX/NaiveProxy domain already has a certificate, pass it explicitly:

```bash
sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --rixxx-domain naive.example.com \
  --reality-dest reality.example.com \
  --rixxx-email admin@example.com \
  --tls-cert /etc/letsencrypt/live/naive.example.com/fullchain.pem \
  --tls-key /etc/letsencrypt/live/naive.example.com/privkey.pem \
  --install \
  --yes
```

If no certificate paths are provided, all-in-one mode first tries nginx HTTP-01 on port `80`. If that fails, it tries a standalone certbot fallback after checking that port `80` is free. The same certificate is used by caddy-naive.

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

For x-ui, WARP mode prepares one `warp-cli` SOCKS outbound and one AI-domain routing snippet. By default it does not write directly into the x-ui routing settings DB, because that path can make 3x-ui inbound edits unstable on some panel versions. Generated clients stay on enabled preset inbounds.

Fresh latest installs that include x-ui (`--mode xui`, `--mode both`, or
`--mode all`) install the stable x-ui-pro-like core by default:

- one VLESS TCP REALITY inbound routed by nginx stream SNI to its backend port;
- one VLESS WS inbound routed through the x-ui HTTPS vhost path proxy;
- one VLESS XHTTP inbound routed through the same path proxy;
- one Trojan gRPC inbound routed through the same path proxy.

VMess is intentionally omitted because it is deprecated. The older broad preset
mix is still available with `--xui-extended-presets`; it adds extra REALITY
decoys, Shadowsocks, Hysteria2, and Trojan TCP REALITY. Use it only when you
need those links and accept the larger nginx/SNI surface.

When testing REALITY profiles through a client-side TUN inbound, disable
destination override sniffing or set its `routeOnly` option to `true`. Otherwise
the REALITY decoy SNI can replace the VPS uplink address: for example, a client
that should connect to `vpn.example.com:12345` may incorrectly dial
`ya.ru:12345`. Test imported profiles with TUN disabled first.

Repair and regenerate x-ui inbounds after an update:

```bash
cd ~/unified-proxy-manager
git pull
sudo bash repair-xui-inbounds.sh
```

This is the normal x-ui repair entrypoint. It creates a backup, repairs the
generated presets, refreshes x-ui-only subscriptions, and runs `doctor.sh`.
Internal scripts remain separate modules so installation, diagnostics, and
profile generation can still be tested independently. It also rewrites
recursively expanded legacy profile names to stable short names without
rotating per-client credentials.

For RIXXX Panel, NaiveProxy split routing remains client-side because Caddy `forward_proxy` has no per-domain outbound ACL. For Mieru, use RIXXX Panel routing controls when supported by the installed panel version.

### Sniffing

Generated preset inbounds get Xray sniffing enabled by default for `http`, `tls`, `quic`, and `fakedns`. This applies to generated x-ui presets. Sniffing lets Xray see the destination domain from HTTP Host, TLS SNI, or QUIC SNI before applying domain routing. Without sniffing, some AI-domain rules can be skipped because Xray only sees an IP.

## Profile Generation

Generate or refresh profiles after installation:

```bash
sudo bash generate-profiles.sh --yes
```

By default this creates 15 x-ui clients on each selected preset inbound. It does
not install WARP and does not write WARP routing.

The default supported x-ui line for fresh installs is latest v3. Use
`install-xui-legacy.sh` only when you intentionally need the fixed `2.9.4`
schema. `generate-profiles.sh` writes clients through the classic
`inbounds.settings.clients` model. For the latest v3 line use:

```bash
sudo bash generate-xui-v3.sh \
  --count 15 \
  --prefix auto \
  --yes
```

The v3 generator writes one row per profile to `clients`, then attaches that
row to every compatible generated inbound through `client_inbounds`.

`generate-xui-v3.sh --reset-inbounds` uses the stable core by default:
`vless tcp reality`, `vless ws`, `vless xhttp`, `trojan grpc`, and
`hysteria2 udp`. Add `--extended-presets` only when you want the larger
experimental preset set.

Extra v3 inbounds for manual WARP routing are created by default without
installing WARP and without writing WARP outbound/routing rules:

```bash
sudo bash generate-xui-v3.sh \
  --xui-warp-presets \
  --hy2-warp-port 24443 \
  --yes
```

This creates enabled manual WARP prep inbounds for `vless tcp reality`,
`vless xhttp reality`, and `hysteria2 udp`, then attaches the same generated
client entities to them. REALITY/XHTTP are still published through public TCP
443 by nginx SNI routing; Hysteria2 uses the UDP port from `--hy2-warp-port`.
Use `--no-xui-warp-presets` if you do not want the WARP prep inbounds.

Default output:

```text
x-ui:
  15 generated clients per selected preset inbound
  one x-ui subscription subId per client index
  WARP prep inbounds generated, but no WARP routing unless explicitly enabled

RIXXX:
  NaiveProxy and Mieru users are managed in RIXXX Panel
  use rixxx-panel-access.sh to recover or reset panel credentials
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
```

RIXXX Panel data:

```text
/etc/rixxx-panel/config.json
/etc/rixxx-panel/access-info.env
/var/lib/rixxx-panel/db.sqlite
```

Generated x-ui link names use the Reality client name as the base. RIXXX NaiveProxy and Mieru users are created inside RIXXX Panel and are independent from 3x-ui clients.

Use RIXXX Panel to create/download NaiveProxy and Mieru client configs. Use the 3x-ui panel or x-ui subscription endpoint for Xray links.

## Optional x-ui Subscription Domain

The default install does not expose a custom x-ui subscription domain. If you need a dedicated HTTPS subscription URL for x-ui clients, use the separate module:

```bash
sudo bash configure-xui-subscription.sh --show
sudo bash configure-xui-subscription.sh --interactive
```

Non-interactive example:

```bash
sudo bash configure-xui-subscription.sh \
  --domain SUB_DOMAIN \
  --port SUB_PORT \
  --path /SUB_PATH/ \
  --sub-id SUB_ID \
  --yes
```

For the latest 3x-ui line, add `--client-email CLIENT_EMAIL` to set that
client's `sub_id` to `--sub-id`. Example: `--client-email auto-01 --sub-id Tin`
serves the client at `/Tin`.

Do not use the same domain for this subscription endpoint and Reality SNI/serverName. nginx stream routes public `443/tcp` by SNI, so reusing the subscription SNI for Reality sends Reality traffic to the subscription backend.

Full setup notes and placeholder-only examples are in [docs/xui-subscription-domain.md](docs/xui-subscription-domain.md).

## Access Info

After install or profile generation:

```bash
sudo bash show-access-info.sh
sudo cat access-info.txt
```

The access summary includes panel URLs, generated credentials, service hints, WARP details when configured, and a profiles section when generated files are present.

For RIXXX Panel only:

```bash
sudo bash rixxx-panel-access.sh
```

If the RIXXX plaintext admin password was not saved, reset it:

```bash
sudo bash rixxx-panel-access.sh --reset-password
```

## Fake Error Site

Install or refresh the local static fallback site without reinstalling the stack:

```bash
sudo bash install-fake-site.sh --patch-nginx --yes
```

The page is served from `/var/www/html` and reads the current browser hostname,
path, protocol, request time, and request id in the browser, so the same file can
be reused for any installed domain.

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

The recommended profile keeps SSH, `80/tcp`, `443/tcp`, and the published ports
of enabled x-ui presets open. In stable core this normally includes public
`443/tcp` plus Hysteria2 UDP ports such as `443/udp` and the WARP prep HY2 UDP
port. Extended presets can add ports such as Shadowsocks TCP. It closes public
RIXXX Panel port `8081/tcp`, installs fail2ban and
unattended-upgrades, enables `probe_resistance` in `/etc/caddy-naive/Caddyfile`,
and restricts access files to `0600`.

Access RIXXX Panel through an SSH tunnel after hardening:

```bash
ssh -L 8081:127.0.0.1:8081 root@SERVER_IP
```

Then open:

```text
http://127.0.0.1:8081
```

Allow an extra public port only when needed:

```bash
sudo bash security-hardening.sh --apply --yes --allow-port 2053/tcp
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

The uninstaller stops and disables stack services, backs up removed files under `/opt/unified-proxy-manager/backups/uninstall-*`, removes x-ui/RIXXX/caddy-naive/Hysteria stack files, removes stack nginx snippets and sites, cleans stack cron entries, and keeps reusable certificate stores.

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
bash -n install.sh install-unified.sh install-xui-legacy.sh install-xui-latest.sh install-warp.sh generate-profiles.sh generate-xui-v3.sh repair-xui-inbounds.sh status.sh doctor.sh show-access-info.sh uninstall-stack.sh
bash install.sh --mode all --xui-domain x.example.com --rixxx-domain n.example.com --reality-dest r.example.com --rixxx-email a@example.com --dry-run
bash install-warp.sh --help
bash generate-profiles.sh --help
bash tests/common-regression.sh
bash tests/xui-routing-regression.sh
bash tests/xui-routing-443-regression.sh
bash tests/xui-v3-regression.sh
```

On Windows, use a working WSL or Git/MSYS Bash. The real target is Ubuntu 22.04/24.04 or Debian 12.

## Repository Layout

```text
.
+-- components/
|   +-- x-ui-pro/
|   +-- rixxx-panel/
|   +-- nm-panel/
+-- docs/
|   +-- ARCHITECTURE.md
|   +-- PORTS.md
+-- lib/
|   +-- common.sh
|   +-- warp.sh
|   +-- xui-routing.sh
|   +-- xui-v3.sh
+-- install.sh
+-- install-unified.sh
+-- install-xui-legacy.sh
+-- install-xui-latest.sh
+-- install-warp.sh
+-- generate-profiles.sh
+-- generate-xui-v3.sh
+-- repair-xui-inbounds.sh
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
- Generated x-ui profiles use only the normal preset inbounds unless v3 generation is run with `--xui-warp-presets`. Normal WARP mode is server-side routing through the `warp-cli` outbound, not separate legacy `*-warp` clone inbounds.
