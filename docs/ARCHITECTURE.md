# Architecture

This project has a dry-run planner and an explicit real installer.

## Boundary

`unified-proxy-manager` uses curated vendored component copies under `components/`:

```text
components/x-ui-pro
components/rixxx-panel
components/nm-panel
```

The manager reads system state, validates the vendored component files, and either prints a plan or runs the explicit guarded installer. It no longer keeps local clone directories for external projects.

## Scripts

- `install.sh` accepts `--mode xui`, `--mode naive`, `--mode all`, `--mode both`, or `--mode nh`, validates required domain arguments, checks OS/commands/services/ports/DNS, and prints a dry-run plan.
- `status.sh` reports configured domains, service states, listening ports, and recent service logs when available.
- `doctor.sh` performs diagnostic checks and prints recommendations.
- `repair-xui-inbounds.sh` is the single operator-facing x-ui repair command. It backs up the database, applies narrowly scoped preset repairs, regenerates x-ui profiles, and runs `doctor.sh`.

## Shared Libraries

Common Bash behavior lives under `lib/` and is sourced by the public scripts instead of being copied across entrypoints:

- `lib/common.sh`: logging adapters, command checks, SQL quoting, nginx stream include helper, and guarded `config.env` updates.
- `lib/warp.sh`: default AI domain list, WARP readiness checks, auto-install wrapper, and Xray snippet generation.
- `lib/xui-routing.sh`: x-ui preset inbound filtering, sniffing enablement, WARP snippet generation, and explicit opt-in WARP template apply/remove.

The supported x-ui WARP model is normal x-ui inbounds plus a local SOCKS proxy at `127.0.0.1:40000`. Profile generation writes the AI-domain routing snippet by default and does not edit x-ui routing settings unless `XUI_APPLY_WARP_TEMPLATE=1` or `--apply-xui-warp-template` is used. The project no longer creates or deletes `*-warp` clone inbounds.

RIXXX Panel manages NaiveProxy and Mieru. NaiveProxy split routing is client-side because Caddy `forward_proxy` has no server-side per-domain outbound ACL. Mieru routing depends on the installed RIXXX panel controls.

## Resulting Panels

The current implementation installs the full stack in one command, while keeping the management dashboards separate.

- x-ui-pro / 3x-ui remains the management panel for Xray/3x-ui.
- RIXXX Panel remains the management panel for NaiveProxy + Mieru.
- `--mode all` installs x-ui-pro plus RIXXX Panel, NaiveProxy, and Mieru.
- `--mode nh` installs NaiveProxy + Mieru through the RIXXX Panel, without 3x-ui.

A true single dashboard that manages NaiveProxy + Mieru + 3x-ui together would still need a dedicated integration layer.

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
- RIXXX Caddy/NaiveProxy binds only `127.0.0.1:9445`;
- nginx stream routes the RIXXX/NaiveProxy SNI domain to `127.0.0.1:9445`;
- Mieru binds its configured public TCP/UDP port range, usually starting at `2012`;
- x-ui extended presets can add separate ports such as Hysteria2 UDP, but stable
  core keeps x-ui public entrypoints on nginx-managed `443/tcp`.

## RIXXX Standalone Mode

`--mode nh` remains available for installing only the RIXXX Panel + NaiveProxy + Mieru stack. Use `--mode all` for 3x-ui + RIXXX together.
