# xuinaive

Unified installer for all components on one VPS:

- x-ui-pro / 3x-ui / Xray / nginx;
- RIXXX Panel / NaiveProxy / Caddy backend;
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
└── rixxx-panel/
```

## What You Get

- `--mode all`: installs 3x-ui / x-ui-pro plus RIXXX Panel, NaiveProxy, and Hysteria2 on one VPS.
- nginx from x-ui-pro owns public `443/tcp`.
- RIXXX Caddy/NaiveProxy runs behind nginx on `127.0.0.1:9445`.
- Hysteria2 uses public `443/udp`.
- You still get two web panels: 3x-ui for Xray/3x-ui and RIXXX Panel for NaiveProxy + Hysteria2.

## Quick Start From VPS

One command for real unified install on a fresh VPS:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/YOUR_USER/YOUR_REPO.git unified-proxy-manager
cd unified-proxy-manager
sudo bash install.sh --mode all \
  --xui-domain xui.example.com \
  --rixxx-domain naive.example.com \
  --reality-dest reality.example.com \
  --rixxx-email admin@example.com \
  --install \
  --yes
```

Dry-run only:

```bash
cd /root
rm -rf unified-proxy-manager
git clone https://github.com/YOUR_USER/YOUR_REPO.git unified-proxy-manager
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

- mode: `xui`, `naive`, `all`, `both`, or `rixxx`;
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
  --rixxx-domain n.example.com \
  --reality-dest r.example.com \
  --rixxx-email admin@example.com \
  --dry-run
```

Standalone RIXXX panel plan:

```bash
sudo bash install.sh --mode rixxx \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --dry-run
```

Real RIXXX panel install:

```bash
sudo bash install.sh --mode rixxx \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --rixxx-stack both \
  --rixxx-access nginx8080 \
  --install \
  --yes
```

With a separate HTTPS panel subdomain:

```bash
sudo bash install.sh --mode rixxx \
  --domain vpn.example.com \
  --proxy-email admin@example.com \
  --rixxx-access subdomain \
  --panel-domain panel.example.com \
  --panel-email admin@example.com \
  --install \
  --yes
```

Status:

```bash
sudo ./status.sh
```

Doctor:

```bash
sudo ./doctor.sh
```

## What install.sh checks

- root or non-root execution warning;
- OS support: Ubuntu 22.04, Ubuntu 24.04, Debian 12;
- required commands: `curl`, `wget`, `git`, `systemctl`;
- upstream script presence;
- service states for `x-ui`, `nginx`, `caddy-rixxx`, `ufw`;
- service states for `hysteria-server` and `panel-naive-hy2` when present;
- listeners on `80`, `443`, `2053`, `8443`, `9443`;
- DNS A records for provided domains against current public IPv4;
- 443 conflict risk and SNI backend layout for `all` mode.

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
  --rixxx-domain naive.example.com \
  --reality-dest reality.example.com \
  --rixxx-email admin@example.com \
  --install \
  --yes
```

This installer uses one public `443` owner:

- x-ui-pro/nginx listens on public `443`;
- RIXXX NaiveProxy/Caddy listens on `127.0.0.1:9445`;
- nginx stream routes the RIXXX/NaiveProxy domain by SNI to `127.0.0.1:9445`;
- Hysteria2 listens on public `443/udp`;
- RIXXX Panel is available through nginx on `8081` by default.

Warning: `install-unified.sh` runs the vendored x-ui-pro installer, which is destructive like upstream. Use it only on a fresh VPS or after backups.

## Legacy / Standalone Modes

`--mode rixxx` still exists for a standalone RIXXX Panel install without 3x-ui. For one-command 3x-ui + RIXXX, use `--mode all`.
