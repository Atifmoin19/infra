#!/bin/bash
# shellcheck source=lib.sh
. /opt/bin/lib.sh
prefix_output portfolio
use_env PORTFOLIO
# Firebase service account: base64 JSON in PORTFOLIO__FIREBASE_SERVICE_ACCOUNT_B64 -> 0600 file.
if [ -n "${FIREBASE_SERVICE_ACCOUNT_B64:-}" ]; then
	umask 077
	mkdir -p /tmp/secrets
	printf '%s' "$FIREBASE_SERVICE_ACCOUNT_B64" | base64 -d > /tmp/secrets/firebase-service-account.json
	export FIREBASE_SERVICE_ACCOUNT_PATH=/tmp/secrets/firebase-service-account.json
	unset FIREBASE_SERVICE_ACCOUNT_B64
fi
cd /srv/portfolio || exit 1
exec /opt/venv-portfolio/bin/uvicorn app.main:app --host 127.0.0.1 --port 8001 \
	--proxy-headers --root-path /portfolio --no-server-header
