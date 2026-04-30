# Architecture

This first version is a safe planner, not an installer.

## Boundary

`unified-proxy-manager` keeps upstream repositories inside its own `upstreams/` directory:

```text
upstreams/x-ui-pro
upstreams/naiveproxy-instant-install-by-Ilya_Rublev
```

Run `./prepare-upstreams.sh` to clone or refresh those upstream repositories. The manager reads system state and prints a plan. It does not modify upstream code and does not execute upstream installers.

## Scripts

- `install.sh` accepts `--mode xui`, `--mode naive`, or `--mode both`, validates required domain arguments, checks OS/commands/services/ports/DNS, and prints a dry-run plan.
- `prepare-upstreams.sh` creates `upstreams/` and clones the upstream projects there.
- `status.sh` reports configured domains, service states, listening ports, and recent service logs when available.
- `doctor.sh` performs diagnostic checks and prints recommendations.

## Future Real Installer Shape

A later version can add guarded execution with:

- explicit confirmation;
- backups before touching `/etc/nginx`, `/etc/caddy`, `/etc/x-ui`, `/usr/local/x-ui`;
- logging;
- refusal to continue when public `80/443` are already occupied by an incompatible service.

That behavior is intentionally not present in this first safe version.

## Both Mode

Both upstream stacks want public `443`:

- x-ui-pro uses nginx stream on `443`;
- NaiveProxy uses Caddy on `443`.

For one VPS, a future real deployment needs either:

- separate VPS instances; or
- one reviewed front SNI router on `443`, with x-ui-pro and Caddy moved to loopback backend ports.

This version only warns and explains the conflict.
