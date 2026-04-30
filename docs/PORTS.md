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

## Unified Vendored Layout

- `443/tcp`: public nginx stream SNI router.
- `7443/tcp`: x-ui-pro HTTPS/web backend.
- `8443/tcp`: x-ui-pro REALITY backend.
- `9443/tcp`: x-ui-pro REALITY destination nginx backend.
- `9444/tcp` on `127.0.0.1`: NaiveProxy/Caddy backend service `caddy-naive`.

In unified mode, NaiveProxy clients still connect to external `443`; nginx stream routes the NaiveProxy domain SNI to `127.0.0.1:9444`.

## Checked By This Version

`install.sh`, `status.sh`, and `doctor.sh` check:

- `80`;
- `443`;
- `2053`;
- `8443`;
- `9443`.
- `9444`.

`status.sh` also reports `7443` and `8080` because they are common local x-ui-pro related ports.

## Conflict Rule

On one VPS, only one process should own public 443. For both stacks, use a single SNI router or split the components across different VPS instances.
