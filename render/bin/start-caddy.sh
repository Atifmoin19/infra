#!/bin/bash
# shellcheck source=lib.sh
. /opt/bin/lib.sh
prefix_output caddy
use_env NONE
mkdir -p /tmp/caddy
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
