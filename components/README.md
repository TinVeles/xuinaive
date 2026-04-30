# Vendored Components

This directory contains local copies of upstream projects used by the unified installer.

```text
components/
├── x-ui-pro/
│   ├── x-ui-pro.sh
│   └── apply-naive-sni-route.sh
└── naiveproxy/
    ├── install.sh
    ├── install.upstream-original.sh
    └── install-unified-backend.sh
```

The unified layout keeps one public HTTPS entrypoint:

- nginx stream from x-ui-pro owns public `0.0.0.0:443`;
- x-ui-pro REALITY backend stays on `127.0.0.1:8443`;
- x-ui-pro HTTPS/web backend stays on `127.0.0.1:7443`;
- NaiveProxy/Caddy is moved to `127.0.0.1:9444`;
- nginx stream routes the NaiveProxy domain SNI to `127.0.0.1:9444`.

Use `../install-unified.sh --mode both --yes` for the explicit real installer.

`components/naiveproxy/install.sh` is intentionally replaced with a unified wrapper.
The original upstream interactive installer is kept as `install.upstream-original.sh`.
