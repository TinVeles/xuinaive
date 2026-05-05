# Upstream Audit

Дата аудита: 2026-04-30.

Аудит выполнен без запуска install/uninstall-скриптов.

## x-ui-pro

Репозиторий: `../x-ui-pro`

Основные скрипты:

- `x-ui-pro.sh` - основной установщик x-ui-pro / 3x-ui stack.
- `apply-naive-sni-route.sh` - локальный unified-патч nginx stream для маршрутизации N+H/NaiveProxy SNI на backend `127.0.0.1:9445`.

Очистка vendored-копии:

- альтернативные версии `x-ui-pro-updated.sh` и `x-ui-pro-old.sh` удалены;
- upstream helper-скрипты `backup.sh`, `randomfakehtml.sh`, `repare-after-286-update.sh` удалены;
- документационные изображения, примеры Clash и HTML subscription pages удалены;
- оставлены только файлы, которые реально нужны unified-установщику.

Ключевой риск:

- `x-ui-pro.sh` выполняет разрушительные действия в начале файла до полноценной установки:
  - `systemctl stop x-ui`;
  - удаляет `/etc/systemd/system/x-ui.service`;
  - удаляет `/usr/local/x-ui`;
  - удаляет `/etc/x-ui`;
  - удаляет `/etc/nginx/sites-enabled/*`;
  - удаляет `/etc/nginx/sites-available/*`;
  - удаляет `/etc/nginx/stream-enabled/*`.
- Скрипт также выполняет `fuser -k 80/tcp 80/udp 443/tcp 443/udp`, то есть убивает процессы на 80/443.
- Поэтому unified wrapper не должен запускать этот upstream без явной предварительной проверки, backup и подтверждения оператора.

Пакеты:

- Через `apt` или `yum` выбирается пакетный менеджер.
- Для установки используются `curl`, `wget`, `jq`, `bash`, `sudo`, `nginx-full`, `certbot`, `python3-certbot-nginx`, `sqlite3`, `ufw`, `tar`, `tzdata`, `ca-certificates`.

Systemd/services:

- Создается/обновляется `/etc/systemd/system/x-ui.service` из upstream 3x-ui release.
- Управление: `systemctl enable/start/restart x-ui`.
- Включается и запускается `nginx`.
- `sub2sing-box` запускается через crontab `@reboot`, отдельный systemd service для него не создается.

Порты:

- `80/tcp` - nginx redirect to HTTPS и ACME/HTTP.
- `443/tcp` - nginx stream SNI entrypoint.
- `7443/tcp` - локальный nginx TLS vhost для panel/websocket domain.
- `8443/tcp` - Xray REALITY inbound.
- `9443/tcp` - локальный nginx TLS vhost для REALITY destination.
- `8080/tcp` на `127.0.0.1` - local `sub2sing-box`.
- Несколько случайных high ports для panel/sub/ws/trojan.
- В коде есть исключение для `2053`, но основной public listener скрипта - 443.

Файлы конфигурации:

- `/etc/x-ui/x-ui.db`.
- `/usr/local/x-ui`.
- `/usr/bin/x-ui`.
- `/etc/systemd/system/x-ui.service`.
- `/etc/nginx/nginx.conf`.
- `/etc/nginx/stream-enabled/stream.conf`.
- `/etc/nginx/sites-available/80.conf`.
- `/etc/nginx/sites-available/<xui-domain>`.
- `/etc/nginx/sites-available/<reality-domain>`.
- `/etc/nginx/sites-enabled/*`.
- `/etc/nginx/snippets/includes.conf`.
- `/root/cert/<domain>/*` symlinks to Let's Encrypt certs.
- `/var/www/html`, `/var/www/subpage`.
- `/etc/sysctl.conf`.
- root crontab entries for `sub2sing-box`, x-ui restart/nginx reload, certbot renew.

SSL:

- `certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email`.
- Certificates expected in `/etc/letsencrypt/live/<domain>/`.

Firewall:

- Calls `ufw disable`.
- Then allows `22/tcp`, `80/tcp`, `443/tcp`.
- Then `ufw --force enable`.

## Removed legacy NaiveProxy installer

The old standalone NaiveProxy component has been removed from the active installer flow. The all-in-one flow now uses the N+H Panel NaiveProxy backend on loopback behind nginx stream.

Основной скрипт:

- `install.sh` - interactive installer.

Interactive inputs:

- `DOMAIN` via `read -p`.
- `EMAIL` via `read -p`.

Пакеты:

- `apt update && apt upgrade -y`.
- `apt install -y wget curl nano ufw tar libcap2-bin`.
- Скачивает Go `go1.22.1.linux-amd64.tar.gz`.
- Устанавливает `xcaddy` через `go install`.
- Собирает Caddy с модулем:
  `github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive`.

Systemd/services:

- Создает `/etc/systemd/system/caddy.service`.
- Управление: `systemctl daemon-reload`, `systemctl enable caddy`, `systemctl restart caddy`.
- Создает системного пользователя и группу `caddy`.

Порты:

- `443/tcp` - Caddy HTTPS и Naive forward_proxy.
- `443/udp` - открыт в UFW для HTTP/3/QUIC.
- `80/tcp` - открыт в UFW для ACME/HTTP.
- Клиентский пример использует локальный SOCKS `127.0.0.1:1080` на стороне клиента, не на VPS.

Файлы конфигурации:

- `/usr/local/go`.
- `/usr/bin/caddy`.
- `/etc/caddy/Caddyfile`.
- `/etc/systemd/system/caddy.service`.
- `/etc/sysctl.conf`.

Caddyfile:

- Global options:
  - `debug`;
  - `order forward_proxy before reverse_proxy`.
- Site block:
  - `:443, <domain>`;
  - `tls <email>`;
  - `forward_proxy` with generated basic auth;
  - `hide_ip`, `hide_via`, `probe_resistance`;
  - fallback `reverse_proxy https://kernel.org`.

SSL:

- Managed automatically by Caddy through `tls <email>`.

Firewall:

- Allows `OpenSSH`, `80/tcp`, `443/tcp`, `443/udp`.
- Runs `ufw --force enable`.

## Conflict Summary

- Both stacks expect to own public `0.0.0.0:443`.
- `x-ui-pro` expects nginx stream on `443`.
- NaiveProxy expects Caddy on `443`.
- Running both upstream installers unchanged on one VPS is unsafe because both write global service configs and both want 443.
- Safe deployment choices:
  - Scheme A: x-ui-pro and NaiveProxy on different VPS instances.
  - Scheme B: one VPS with a single front SNI router on 443 and backend services on separate loopback ports. This requires deliberate nginx stream/Caddy bind changes and must not be applied automatically without explicit operator action.
