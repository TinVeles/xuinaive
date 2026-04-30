# xuinaive

Unified installer for two components on one VPS:

- x-ui-pro / 3x-ui / Xray / nginx;
- NaiveProxy / Caddy backend.

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
└── naiveproxy/
```

## Quick Start From VPS

One command for real unified install on a fresh VPS:

```bash
cd /root
rm -rf xuinaive
git clone https://github.com/TinVeles/xuinaive.git
cd xuinaive
sudo bash install.sh --mode both \
  --xui-domain zaiki.abamikink.zanity.net \
  --naive-domain sub.abamikink.zanity.net \
  --reality-dest abamikink.zanity.net \
  --naive-email yonkie3762owl765892eagle@gmail.com \
  --install \
  --yes
```

Dry-run only:

```bash
cd /root
rm -rf xuinaive
git clone https://github.com/TinVeles/xuinaive.git
cd xuinaive
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

- mode: `xui`, `naive`, or `both`;
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

Both components plan:

```bash
sudo bash install.sh --mode both --xui-domain x.example.com --naive-domain n.example.com --reality-dest r.example.com --dry-run
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
- service states for `x-ui`, `nginx`, `caddy`, `ufw`;
- listeners on `80`, `443`, `2053`, `8443`, `9443`;
- DNS A records for provided domains against current public IPv4;
- 443 conflict risk for `both` mode.

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

Direct real installer command through `install.sh`:

```bash
sudo bash install.sh --mode both \
  --xui-domain zaiki.abamikink.zanity.net \
  --naive-domain sub.abamikink.zanity.net \
  --reality-dest abamikink.zanity.net \
  --naive-email yonkie3762owl765892eagle@gmail.com \
  --install \
  --yes
```

This installer uses one public `443` owner:

- x-ui-pro/nginx listens on public `443`;
- NaiveProxy/Caddy listens on `127.0.0.1:9444`;
- nginx stream routes the NaiveProxy domain by SNI to `127.0.0.1:9444`.

Warning: `install-unified.sh` runs the vendored x-ui-pro installer, which is destructive like upstream. Use it only on a fresh VPS or after backups.
