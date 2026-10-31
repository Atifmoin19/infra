#!/bin/bash
# shellcheck source=lib.sh
. /opt/bin/lib.sh
prefix_output expense
use_env EXPENSE
cd /srv/expense || exit 1
/opt/venv-expense/bin/alembic upgrade head || exit 1
exec /opt/venv-expense/bin/uvicorn main:app --host 127.0.0.1 --port 8002 \
	--proxy-headers --root-path /expense --no-server-header
