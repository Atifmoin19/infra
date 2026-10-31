#!/bin/bash
# shellcheck source=lib.sh
. /opt/bin/lib.sh
prefix_output dayline
use_env DAYLINE
# Single-process mode: no Redis, no Celery; the API runs its periodic jobs in-process and
# keeps sessions in Postgres. Root path is fixed by the router, not configurable.
export CELERY_ENABLED=false API_ROOT_PATH=/dayline
unset REDIS_URL REDIS_HOST
cd /srv/dayline || exit 1
/opt/venv-dayline/bin/alembic upgrade head || exit 1
exec /opt/venv-dayline/bin/uvicorn main:app --host 127.0.0.1 --port 8003 \
	--proxy-headers --no-server-header
