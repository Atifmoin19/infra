#!/bin/bash
# shellcheck source=lib.sh
. /opt/bin/lib.sh
prefix_output health
use_env NONE
exec python /opt/bin/health.py
