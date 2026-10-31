# Override Dockerfile for ExpenseTrackerBE / All Square (build context: ../ExpenseTrackerBE).
# Differs from the repo's own Dockerfile (kept for Render) in that it:
#   - runs as a non-root user (uid 10001)
#   - copies only source dirs (the repo has no .dockerignore, so `COPY . .` would bake in .env)
#   - multi-stage build, HEALTHCHECK on /health
#   - uvicorn --proxy-headers --root-path /expense, after `alembic upgrade head`
FROM python:3.11-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    ROOT_PATH=/expense \
    FORWARDED_ALLOW_IPS=*
RUN groupadd -g 10001 app && useradd -u 10001 -g app -M -s /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY main.py alembic.ini ./
COPY alembic ./alembic
COPY core ./core
COPY models ./models
COPY routers ./routers
COPY schemas ./schemas
COPY services ./services
COPY utils ./utils
COPY scripts ./scripts
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"
# FORWARDED_ALLOW_IPS=* is safe: only Caddy can reach this container, and Caddy overwrites
# X-Forwarded-For with the real client IP (untrusted incoming XFF is discarded), so
# request.client.host -> the per-IP demo / rate limits see the real visitor.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn main:app --host 0.0.0.0 --port 8000 --proxy-headers --root-path \"$ROOT_PATH\""]
