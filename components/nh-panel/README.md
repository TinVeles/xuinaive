# N+H Panel Component

Vendored N+H Panel component for NaiveProxy and Hysteria2.

This component installs the N+H Panel stack:

- Node.js web panel on port `3000`;
- NaiveProxy through Caddy on public `443/tcp`;
- Hysteria2 on public `443/udp`;
- optional panel exposure through `8080`, direct `3000`, panel subdomain, or SSH-only mode.

## Standalone Install

Interactive upstream-compatible install:

```bash
sudo ./components/nh-panel/install.sh
```

Automated install:

```bash
sudo ./components/nh-panel/install.sh \
  --stack both \
  --access nginx8080 \
  --domain vpn.example.com \
  --email admin@example.com \
  --yes
```

With a panel subdomain:

```bash
sudo ./components/nh-panel/install.sh \
  --stack both \
  --access subdomain \
  --domain vpn.example.com \
  --email admin@example.com \
  --panel-domain panel.example.com \
  --panel-email admin@example.com \
  --yes
```

Update an existing N+H panel install:

```bash
sudo ./components/nh-panel/update.sh --status
sudo ./components/nh-panel/update.sh
```

## Important

This is a standalone public `443` stack. Do not run it on the same VPS as the current `x-ui-pro` unified layout unless you have intentionally reviewed the port and service conflicts. The current `x-ui-pro + NaiveProxy` layout uses nginx stream as the public `443` owner; N+H uses Caddy for public `443/tcp` and Hysteria2 for `443/udp`.
