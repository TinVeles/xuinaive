#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ss() {
  printf '%s\n' \
    'tcp LISTEN 0 4096 0.0.0.0:11366 0.0.0.0:* users:xray' \
    'udp UNCONN 0 0 *:10659 *:* users:xray' \
    'tcp LISTEN 0 511 [::]:443 [::]:* users:nginx'
}

[[ "$(upm_port_details 11366 | wc -l)" == "1" ]]
[[ "$(upm_port_details 10659 | wc -l)" == "1" ]]
[[ "$(upm_port_details 443 | wc -l)" == "1" ]]
[[ "$(upm_port_details 9999 | wc -l)" == "0" ]]
[[ "$(upm_port_details 443 tcp | wc -l)" == "1" ]]
[[ "$(upm_port_details 443 udp | wc -l)" == "0" ]]
[[ "$(upm_port_details 10659 udp | wc -l)" == "1" ]]

printf 'common regression OK\n'
