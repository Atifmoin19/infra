# Override Dockerfile for NextPortfolio/Backend (build context: ../NextPortfolio/Backend).
# Differs from the repo's own Dockerfile (kept for Render) in that it:
#   - runs as a non-root user (uid 10001)
#   - copies only requirements.txt + app/ (secrets/.env can never land in the image)
#   - uses a multi-stage build so build tooling isn't in the final image
#   - has a HEALTHCHECK on /health
#   - runs uvicorn with --root-path /portfolio so generated URLs (/docs, openapi) are correct
#     behind Caddy's `handle_path /portfolio/*`.
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    ROOT_PATH=/portfolio \
    FORWARDED_ALLOW_IPS=*
RUN groupadd -g 10001 app && useradd -u 10001 -g app -M -s /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY --chown=root:root app ./app
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"
# FORWARDED_ALLOW_IPS=* is safe: the container is only reachable from Caddy on the internal network.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --root-path \"$ROOT_PATH\""]
