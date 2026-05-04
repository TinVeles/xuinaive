# Architecture

This project has a dry-run planner and an explicit real installer.

## Boundary

`unified-proxy-manager` keeps upstream repositories inside its own `upstreams/` directory:

```text
upstreams/x-ui-pro
upstreams/NH-Panel-Naive-Hy2
```

Run `./prepare-upstreams.sh` to clone or refresh those upstream repositories. The manager reads system state and prints a plan. It does not modify upstream code and does not execute upstream installers.

## Scripts

- `install.sh` accepts `--mode xui`, `--mode naive`, `--mode all`, `--mode both`, or `--mode nh`, validates required domain arguments, checks OS/commands/services/ports/DNS, and prints a dry-run plan.
- `prepare-upstreams.sh` creates `upstreams/` and clones the upstream projects there.
- `status.sh` reports configured domains, service states, listening ports, and recent service logs when available.
- `doctor.sh` performs diagnostic checks and prints recommendations.

## Resulting Panels

The current implementation installs the full stack in one command, while keeping the management dashboards separate.

- x-ui-pro / 3x-ui remains the management panel for Xray/3x-ui.
- N+H panel remains the management panel for NaiveProxy + Hysteria2.
- `--mode all` installs x-ui-pro plus N+H Panel, NaiveProxy, and Hysteria2.
- `--mode nh` installs NaiveProxy + Hy2 through the N+H panel, without 3x-ui.

A true single dashboard that manages NaiveProxy + Hysteria2 + 3x-ui together would still need a dedicated integration layer.

## Real Installer Safety

A later version can add guarded execution with:

- explicit confirmation;
- backups before touching `/etc/nginx`, `/etc/caddy`, `/etc/x-ui`, `/usr/local/x-ui`;
- logging;
- refusal to continue when public `80/443` are already occupied by an incompatible service.

Real installation is gated behind `--install --yes`.

## All Mode

`--mode all` resolves the public `443/tcp` conflict this way:

- x-ui-pro nginx stream owns public `443/tcp`;
- N+H Caddy/NaiveProxy binds only `127.0.0.1:9445`;
- nginx stream routes the N+H/NaiveProxy SNI domain to `127.0.0.1:9445`;
- Hysteria2 binds public `443/udp`, which does not conflict with nginx TCP.

## N+H Standalone Mode

`--mode nh` remains available for installing only the N+H Panel + NaiveProxy + Hysteria2 stack. Use `--mode all` for 3x-ui + N+H together.
