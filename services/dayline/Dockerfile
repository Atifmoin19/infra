# Override Dockerfile for Dayline (taskboard/backend; build context: ../taskboard/backend).
# One image, three roles (compose sets the command): dayline-api, dayline-worker, dayline-beat.
# Differs from the repo's own Dockerfile in that it:
#   - runs as a non-root user (uid 10001)
#   - copies named paths only (*.py, alembic/, alembic.ini, seed/), never `.`
#   - multi-stage (no gcc/libpq-dev in the final image; psycopg2-binary needs neither)
#   - HEALTHCHECK on /health (which also probes the DB)
#   - API: `alembic upgrade head`, then uvicorn --proxy-headers. The FastAPI root_path
#     comes from API_ROOT_PATH (=/dayline), so no --root-path flag is needed.
FROM python:3.10-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM python:3.10-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    API_ROOT_PATH=/dayline \
    FORWARDED_ALLOW_IPS=*
RUN groupadd -g 10001 app && useradd -u 10001 -g app -M -s /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY *.py alembic.ini ./
COPY alembic ./alembic
COPY seed ./seed
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"
# FORWARDED_ALLOW_IPS=* is safe: only Caddy reaches this container and it overwrites
# X-Forwarded-For, so request.client.host (used by the per-IP demo limit) is the real visitor.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn main:app --host 0.0.0.0 --port 8000 --proxy-headers"]
