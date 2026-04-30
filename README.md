# unified-proxy-manager

First safe version of a bash-based meta-manager for two independent upstream components:

- `../x-ui-pro` for x-ui-pro / 3x-ui / Xray / nginx;
- `../naiveproxy-instant-install-by-Ilya_Rublev` for NaiveProxy / Caddy.

This version is dry-run only. It does not install packages, does not write `/etc`, does not start or stop services, and does not execute upstream scripts.

## Files

```text
unified-proxy-manager/
├── AUDIT.md
├── config.example.env
├── install.sh
├── status.sh
├── doctor.sh
├── README.md
└── docs/
    ├── ARCHITECTURE.md
    └── PORTS.md
```

## Setup

```bash
cd unified-proxy-manager
cp config.example.env config.env
nano config.env
```

`config.env` is optional. CLI flags override values loaded from it.

## Dry-run commands

Interactive mode:

```bash
sudo ./install.sh
```

Remote one-liner style, after publishing `install.sh` to a raw GitHub URL:

```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/unified-proxy-manager/install.sh)
```

With flags:

```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/unified-proxy-manager/install.sh) --mode xui --xui-domain x.example.com --reality-dest r.example.com
```

If you run the remote script from outside the project directory, pass `--project-dir` so it can find `config.env` and the local upstream clones:

```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/unified-proxy-manager/install.sh) --project-dir /root/3x-ui_plus_naive-proxy/unified-proxy-manager
```

The script will ask for:

- mode: `xui`, `naive`, or `both`;
- x-ui domain when needed;
- NaiveProxy domain when needed;
- REALITY destination domain when needed;
- email for future NaiveProxy/Caddy TLS planning.

Only x-ui-pro plan:

```bash
sudo ./install.sh --mode xui --xui-domain x.example.com --reality-dest r.example.com --dry-run
```

Only NaiveProxy plan:

```bash
sudo ./install.sh --mode naive --naive-domain n.example.com --dry-run
```

Both components plan:

```bash
sudo ./install.sh --mode both --xui-domain x.example.com --naive-domain n.example.com --reality-dest r.example.com --dry-run
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
