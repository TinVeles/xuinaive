# Vendored Components

This directory contains local copies of upstream projects used by the unified installer.

```text
components/
├── x-ui-pro/
│   ├── x-ui-pro.sh
│   └── apply-naive-sni-route.sh
└── nh-panel/
    ├── install.sh
    ├── install-unified-backend.sh
    ├── update.sh
    └── upstream/
```

The unified layout keeps one public HTTPS entrypoint:

- nginx stream from x-ui-pro owns public `0.0.0.0:443`;
- x-ui-pro REALITY backend stays on `127.0.0.1:8443`;
- x-ui-pro HTTPS/web backend stays on `127.0.0.1:7443`;
- N+H NaiveProxy/Caddy is moved to `127.0.0.1:9445`;
- nginx stream routes the N+H/NaiveProxy domain SNI to `127.0.0.1:9445`;
- Hysteria2 listens on public `443/udp`;
- N+H Panel listens on `3000` and is exposed through nginx `8081` by default.

Use `../install-unified.sh --mode all --yes` for the explicit real installer.

`components/nh-panel/install-unified-backend.sh` is the NaiveProxy backend used by the all-in-one flow. It installs N+H Panel + NaiveProxy + Hysteria2 without taking public `443/tcp` away from nginx.

This means the project currently has two panel surfaces when all components are considered:

- 3x-ui / x-ui-pro panel for Xray/3x-ui;
- N+H panel for NaiveProxy + Hysteria2.

The panels are separate, but one command can install the whole stack with compatible ports.
