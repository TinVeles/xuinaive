# xuinaive / unified-proxy-manager

First safe version of a bash-based meta-manager for two independent upstream components:

- `upstreams/x-ui-pro` for x-ui-pro / 3x-ui / Xray / nginx;
- `upstreams/naiveproxy-instant-install-by-Ilya_Rublev` for NaiveProxy / Caddy.

This version is dry-run only. It does not install packages, does not write `/etc`, does not start or stop services, and does not execute upstream scripts.

## Files

```text
unified-proxy-manager/
├── .gitignore
├── AUDIT.md
├── config.example.env
├── install.sh
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

## Quick Start From VPS

Recommended full project setup:

```bash
cd /root
git clone https://github.com/TinVeles/xuinaive.git
cd xuinaive/unified-proxy-manager
chmod +x install.sh status.sh doctor.sh prepare-upstreams.sh
sudo ./install.sh
```

On first run, `install.sh` will ask whether to fetch upstream projects into:

```text
unified-proxy-manager/upstreams/x-ui-pro/
unified-proxy-manager/upstreams/naiveproxy-instant-install-by-Ilya_Rublev/
```

You can also fetch them without the prompt:

```bash
sudo ./install.sh --fetch-upstreams
```

Then run the planner:

```bash
sudo ./install.sh
```

Or run the helper directly:

```bash
bash prepare-upstreams.sh
```

Quick remote dry-run without cloning the full project:

```bash
wget -qO /tmp/xuinaive-install.sh https://raw.githubusercontent.com/TinVeles/xuinaive/main/install.sh
bash /tmp/xuinaive-install.sh
```

The `/tmp` method can analyze the VPS, ports and DNS, but it will not have the local upstream projects unless you also clone the full repository and run `prepare-upstreams.sh`.

If your VPS supports `/dev/fd`, this one-line form can also work:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/TinVeles/xuinaive/main/install.sh)
```

If you get `bash: /dev/fd/63: No such file or directory`, use the `/tmp/xuinaive-install.sh` method above.

This is still dry-run only. It checks the server and prints the plan.

## Local Setup

```bash
cd unified-proxy-manager
cp config.example.env config.env
nano config.env
bash prepare-upstreams.sh
```

`config.env` is optional. CLI flags override values loaded from it.

`prepare-upstreams.sh` creates this local layout:

```text
unified-proxy-manager/upstreams/
├── x-ui-pro/
│   └── x-ui-pro.sh
└── naiveproxy-instant-install-by-Ilya_Rublev/
    └── install.sh
```

The upstream projects are fetched on the VPS and are not committed into this repository.

## Dry-run commands

Interactive mode:

```bash
sudo ./install.sh
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

## Current Safety Status

This version is intentionally a planner. It is safe to run on a VPS because it only reads system state:

- no package installation;
- no writes to `/etc`;
- no service start/stop/restart;
- no firewall changes;
- no upstream installer execution.
