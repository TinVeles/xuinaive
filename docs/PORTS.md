# Ports

Based on `AUDIT.md`, these are the important upstream ports to check before any real installation.

## x-ui-pro

- `80/tcp`: nginx HTTP redirect and ACME.
- `443/tcp`: nginx stream SNI public entrypoint.
- `7443/tcp`: local nginx TLS vhost for panel/websocket domain.
- Random high TCP ports: Xray REALITY backend internals routed from public
  `443/tcp` by SNI.
- `9443/tcp`: local nginx TLS vhost for REALITY destination.
- `8080/tcp` on `127.0.0.1`: `sub2sing-box`.
- `443/udp`: x-ui Hysteria2 preset only when extended presets are enabled in
  x-ui-only mode.
- `8388/tcp`: x-ui Shadowsocks only when extended presets are enabled.
- Random high ports: panel/sub/ws internals.

## NaiveProxy

- `80/tcp`: ACME/HTTP.
- `443/tcp`: Caddy HTTPS and Naive forward_proxy.
- `443/udp`: opened for HTTP/3/QUIC.

## All-In-One Layout

- `443/tcp`: public nginx stream SNI router.
- `7443/tcp`: x-ui-pro HTTPS/web backend.
- Random high TCP ports: x-ui-pro backend internals routed by nginx from public
  `443/tcp`.
- `9443/tcp`: x-ui-pro REALITY destination nginx backend.
- `9445/tcp` on `127.0.0.1`: RIXXX NaiveProxy/Caddy backend service `caddy-naive`.
- `2012/tcp` and configured Mieru range: RIXXX Mieru service `mita`.
- `24443/udp`: x-ui Hysteria2 only when extended presets are enabled in
  `--mode all`. Override with `XUI_HY2_PUBLIC_PORT` if needed.
- `8388/tcp`: x-ui Shadowsocks only when extended presets are enabled.
- `3000/tcp` on `127.0.0.1`: RIXXX Panel PM2 process `panel-naive-mieru`.
- `40000/tcp` on `127.0.0.1`: optional Cloudflare WARP local proxy when `--install-warp` is used.

In all-in-one mode, NaiveProxy clients still connect to external `443`; nginx stream routes the RIXXX/NaiveProxy domain SNI to `127.0.0.1:9445`. The backend Caddyfile disables automatic HTTP redirects, uses an explicit certificate/key, and enables the `proxy_protocol` listener wrapper before TLS because nginx stream sends PROXY protocol to backend services.

## RIXXX Panel Mode

- `443/tcp`: public Caddy HTTPS and NaiveProxy forward_proxy.
- `2012/tcp` and configured Mieru range: Mieru.
- `3000/tcp`: Node.js panel internal/direct port.
- `8080/tcp`: optional nginx panel proxy mode.
- `80/tcp`: ACME/HTTP.

## Checked By This Version

`install.sh`, `status.sh`, and `doctor.sh` check:

- `80`;
- `443`;
- `2053`;
- `3000`;
- `8080`;
- `8081`;
- `8443`;
- `9443`.
- `9445`.
- `40000` when WARP is enabled.

`status.sh` also reports `7443` and `8080` because they are common local x-ui-pro related ports.

## Conflict Rule

On one VPS, only one process should own public `443/tcp`. In `--mode all`,
nginx owns public `443/tcp`; RIXXX Caddy is moved to loopback. Mieru uses its
own configured public port range. x-ui Hysteria2 uses separate UDP only when
extended presets are explicitly enabled.
