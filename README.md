# xuinaive

Unified installer for all components on one VPS:

- x-ui-pro / 3x-ui / Xray / nginx;
- N+H Panel / NaiveProxy / Caddy backend;
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
├── prepare-upstreams.sh
├── status.sh
├── doctor.sh
├── security-hardening.sh
├── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   └── PORTS.md
└── upstreams/
    └── README.md
```

The repository also contains vendored component copies under `components/`:

```text
components/
├── x-ui-pro/
└── nh-panel/
```

## What You Get

- `--mode all`: installs 3x-ui / x-ui-pro plus N+H Panel, NaiveProxy, and Hysteria2 on one VPS.
- nginx from x-ui-pro owns public `443/tcp`.
- N+H Caddy/NaiveProxy runs behind nginx on `127.0.0.1:9445`.
- Hysteria2 uses public `443/udp`.
- N+H Caddy uses a ready certificate/key and accepts nginx stream PROXY protocol on the backend listener.
- You still get two web panels: 3x-ui for Xray/3x-ui and N+H Panel for NaiveProxy + Hysteria2.

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
  --install \
  --yes
```

If you already have a certificate for the N+H/NaiveProxy domain, pass it explicitly:

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

In `--mode all`, the installer does not let Caddy issue its own certificate on `127.0.0.1:9445`. If `--tls-cert` and `--tls-key` are omitted, it first issues the N+H/NaiveProxy certificate through nginx HTTP-01 on port `80`; if that fails, it automatically tries a standalone certbot fallback after stopping nginx/caddy and checking that `80/tcp` is free. It then configures both Caddy and Hysteria2 to use the same cert/key, installs a renewal deploy hook, and stops the install if backend TLS or public nginx stream TLS does not pass `openssl s_client` checks. The N+H panel is checked on `127.0.0.1:3000`, through local nginx on `127.0.0.1:8081`, and through the server public IP on `8081`; if the last check fails, open `8081/tcp` in the VPS provider firewall/security group.

Dry-run only:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/TinVeles/xuinaive.git unified-proxy-manager
cd unified-proxy-manager
sudo bash install.sh
```

Or run the helper directly:

```bash
bash prepare-upstreams.sh
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

Standalone N+H panel plan:

```bash
sudo bash install.sh --mode nh \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --dry-run
```

Real N+H panel install:

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

The recommended profile keeps only SSH, `80/tcp`, `443/tcp`, and `443/udp` open, closes the N+H panel port `8081/tcp` publicly, installs fail2ban and unattended-upgrades, enables `probe_resistance` in `/etc/caddy-nh/Caddyfile`, and restricts access files to `0600`. After that, access the N+H panel through an SSH tunnel:

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

## What install.sh checks

- root or non-root execution warning;
- OS support: Ubuntu 22.04, Ubuntu 24.04, Debian 12;
- required commands: `curl`, `wget`, `git`, `systemctl`;
- upstream script presence;
- service states for `x-ui`, `nginx`, `caddy-nh`, `ufw`;
- service states for `hysteria-server` and `panel-naive-hy2` when present;
- listeners on `80`, `443`, `2053`, `8443`, `9443`;
- DNS A records for provided domains against current public IPv4;
- N+H backend/public TLS checks and SNI backend layout for `all` mode.
- N+H panel HTTP checks on backend `3000`, nginx proxy `8081`, and public `SERVER_IP:8081`.

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
- N+H NaiveProxy/Caddy listens on `127.0.0.1:9445`;
- nginx stream routes the N+H/NaiveProxy domain by SNI to `127.0.0.1:9445` and Caddy accepts the stream PROXY protocol before TLS;
- Hysteria2 listens on public `443/udp`;
- N+H Panel is available through nginx on `8081` by default.

Warning: `install-unified.sh` runs the vendored x-ui-pro installer, which is destructive like upstream. Use it only on a fresh VPS or after backups.

## Legacy / Standalone Modes

`--mode nh` still exists for a standalone N+H Panel install without 3x-ui. For one-command 3x-ui + N+H, use `--mode all`.
