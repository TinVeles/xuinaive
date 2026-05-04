# Ports

Based on `AUDIT.md`, these are the important upstream ports to check before any real installation.

## x-ui-pro

- `80/tcp`: nginx HTTP redirect and ACME.
- `443/tcp`: nginx stream SNI public entrypoint.
- `7443/tcp`: local nginx TLS vhost for panel/websocket domain.
- `8443/tcp`: Xray REALITY inbound.
- `9443/tcp`: local nginx TLS vhost for REALITY destination.
- `8080/tcp` on `127.0.0.1`: `sub2sing-box`.
- Random high ports: panel/sub/ws/trojan internals.

## NaiveProxy

- `80/tcp`: ACME/HTTP.
- `443/tcp`: Caddy HTTPS and Naive forward_proxy.
- `443/udp`: opened for HTTP/3/QUIC.

## All-In-One Layout

- `443/tcp`: public nginx stream SNI router.
- `7443/tcp`: x-ui-pro HTTPS/web backend.
- `8443/tcp`: x-ui-pro REALITY backend.
- `9443/tcp`: x-ui-pro REALITY destination nginx backend.
- `9445/tcp` on `127.0.0.1`: N+H NaiveProxy/Caddy backend service `caddy-nh`.
- `443/udp`: Hysteria2 service `hysteria-server`.
- `3000/tcp`: N+H Panel service `panel-naive-hy2`.
- `8081/tcp`: nginx HTTP proxy to the N+H Panel by default.

In all-in-one mode, NaiveProxy clients still connect to external `443`; nginx stream routes the N+H/NaiveProxy domain SNI to `127.0.0.1:9445`. The backend Caddyfile disables automatic HTTP redirects, uses an explicit certificate/key, and enables the `proxy_protocol` listener wrapper before TLS because nginx stream sends PROXY protocol to upstreams.

## N+H Panel Mode

- `443/tcp`: public Caddy HTTPS and NaiveProxy forward_proxy.
- `443/udp`: Hysteria2 when enabled.
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

`status.sh` also reports `7443` and `8080` because they are common local x-ui-pro related ports.

## Conflict Rule

On one VPS, only one process should own public `443/tcp`. In `--mode all`, nginx owns public `443/tcp`; N+H Caddy is moved to loopback. Hysteria2 uses `443/udp`, so it can coexist with nginx TCP.
