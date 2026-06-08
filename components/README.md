# Vendored Components

This directory contains local copies of upstream projects used by the unified installer.

```text
components/
├── x-ui-pro/
│   ├── x-ui-pro.sh
│   └── apply-naive-sni-route.sh
├── rixxx-panel/
│   └── install-unified-backend.sh
└── nm-panel/
    ├── install.sh
    └── panel/
```

The unified layout keeps one public HTTPS entrypoint:

- nginx stream from x-ui-pro owns public `0.0.0.0:443`;
- x-ui-pro REALITY backends stay on internal TCP ports and nginx stream routes
  each decoy SNI to its matching backend;
- x-ui-pro HTTPS/web backend stays on `127.0.0.1:7443`;
- RIXXX NaiveProxy/Caddy is moved to `127.0.0.1:9445`;
- nginx stream routes the RIXXX/NaiveProxy domain SNI to `127.0.0.1:9445`;
- Mieru uses its own public TCP/UDP port range;
- the x-ui Hysteria2 preset listens on separate `24443/udp` by default in all mode;
- RIXXX Panel listens on `127.0.0.1:3000` by default and is normally accessed through SSH tunnel.

Use `../install-unified.sh --mode all --yes` for the explicit real installer.

`components/rixxx-panel/install-unified-backend.sh` is the NaiveProxy/Mieru backend used by the all-in-one flow. It installs RIXXX Panel + NaiveProxy + Mieru without taking public `443/tcp` away from nginx.

This means the project currently has two panel surfaces when all components are considered:

- 3x-ui / x-ui-pro panel for Xray/3x-ui;
- RIXXX Panel for NaiveProxy + Mieru.

The panels are separate, but one command can install the whole stack with compatible ports.
