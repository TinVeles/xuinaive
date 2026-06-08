# Optional x-ui Subscription Domain

This module is not part of the default install. Use it only when you want a dedicated public x-ui subscription URL such as:

```text
https://SUB_DOMAIN/SUB_PATH/SUB_ID
```

Do not reuse the subscription domain as a Reality SNI/serverName. Public TCP `443` is routed by nginx stream using SNI. If Reality and the subscription endpoint use the same SNI, Reality clients can be routed to the subscription nginx backend and fail with:

```text
REALITY: received real certificate (potential MITM or redirection)
```

## 1. Pick Values

Use your own values:

```text
XUI_DOMAIN        = domain used by x-ui/Xray links
SUB_DOMAIN        = domain used only for subscription HTTPS
RIXXX_DOMAIN      = domain used by RIXXX/NaiveProxy
REALITY_MASK_HOST = external HTTPS host used only as Reality mask/SNI
SUB_PORT          = x-ui subscription listen port
SUB_PATH          = subscription path, must start and end with /
SUB_ID            = existing x-ui client subId
```

Rules:

- `SUB_DOMAIN` must resolve to the VPS and have a valid certificate.
- `SUB_DOMAIN` must not be used as Reality SNI/serverName.
- `REALITY_MASK_HOST` must not be one of your subscription domains.
- Keep the x-ui subscription "Listen IP" and "Listen Domain" empty unless you know you need to restrict them.

## 2. Install Normally

Example shape only:

```bash
sudo bash install.sh --mode all \
  --xui-domain XUI_DOMAIN \
  --rixxx-domain RIXXX_DOMAIN \
  --reality-dest XUI_DOMAIN \
  --rixxx-email ADMIN_EMAIL \
  --install \
  --yes
```

`--reality-dest` in the installer is still an owned domain because the installer may request certificates for it. After install, set the actual Reality mask in the panel.

## 3. Set Reality In The Panel

In the Reality inbound:

```text
External Proxy host: XUI_DOMAIN
External Proxy port: 443
Security: Reality
Target: REALITY_MASK_HOST:443
SNI / Server Names: REALITY_MASK_HOST
uTLS: chrome
```

Save the inbound and restart x-ui:

```bash
sudo systemctl restart x-ui
```

## 4. Configure The Subscription Domain

Run the optional module:

```bash
cd ~/unified-proxy-manager

sudo bash configure-xui-subscription.sh \
  --domain SUB_DOMAIN \
  --port SUB_PORT \
  --path /SUB_PATH/ \
  --sub-id SUB_ID \
  --yes
```

The module changes only x-ui subscription settings plus nginx routing for `SUB_DOMAIN`.

## 5. Refresh Profiles

After changing Reality SNI or generated clients:

```bash
sudo bash generate-profiles.sh --yes

sudo bash configure-xui-subscription.sh \
  --domain SUB_DOMAIN \
  --port SUB_PORT \
  --path /SUB_PATH/ \
  --sub-id SUB_ID \
  --yes
```

## 6. Check

```bash
curl -k -i https://127.0.0.1:SUB_PORT/SUB_PATH/SUB_ID
curl -i https://SUB_DOMAIN/SUB_PATH/SUB_ID
```

Check that generated Reality links do not contain the subscription domain as SNI:

```bash
curl -fsSL https://SUB_DOMAIN/SUB_PATH/SUB_ID | base64 -d | grep -o 'sni=[^&]*' | sort -u
```

Expected:

```text
sni=REALITY_MASK_HOST
```

Not expected:

```text
sni=SUB_DOMAIN
```
