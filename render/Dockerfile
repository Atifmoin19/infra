# Single-container image for ONE free Render web service: portfolio, All Square (expense) and
# Dayline as separate uvicorn processes under supervisord, routed by Caddy on $PORT.
# Build context: the infra repo root (sources are git submodules in render/src/).
#   docker build -f render/Dockerfile -t fsc-api .
# Python 3.12 for all three (portfolio pins 3.12; expense 3.11 and Dayline 3.10/3.13 deps
# all install and boot on 3.12, verified). Each app gets its own venv: no shared site-packages.
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY render/src/portfolio/requirements.txt /req/portfolio.txt
COPY render/src/expense/requirements.txt /req/expense.txt
COPY render/src/dayline/backend/requirements.txt /req/dayline.txt
RUN set -eux; for app in portfolio expense dayline; do \
      python -m venv /opt/venv-$app; /opt/venv-$app/bin/pip install -q -r /req/$app.txt; \
    done; \
    python -m venv /opt/venv-supervisor; /opt/venv-supervisor/bin/pip install -q supervisor==4.2.5 superlance==2.0.0 "setuptools<81"; \
    /opt/venv-supervisor/bin/python -c "import supervisor.options, superlance.memmon"; \
    find /opt -name '__pycache__' -prune -exec rm -rf {} +

FROM caddy:2.8-alpine AS caddy

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    XDG_CONFIG_HOME=/tmp/caddy XDG_DATA_HOME=/tmp/caddy HOME=/tmp \
    PORT=10000
RUN groupadd -g 10001 app && useradd -u 10001 -g app -M -d /tmp -s /usr/sbin/nologin app
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --from=build /opt /opt

# Named source paths only: never `COPY .`, so no .env / service-account file can get in.
COPY render/src/portfolio/app /srv/portfolio/app
COPY render/src/expense/main.py render/src/expense/alembic.ini /srv/expense/
COPY render/src/expense/alembic /srv/expense/alembic
COPY render/src/expense/core /srv/expense/core
COPY render/src/expense/models /srv/expense/models
COPY render/src/expense/routers /srv/expense/routers
COPY render/src/expense/schemas /srv/expense/schemas
COPY render/src/expense/services /srv/expense/services
COPY render/src/expense/utils /srv/expense/utils
COPY render/src/dayline/backend/*.py render/src/dayline/backend/alembic.ini /srv/dayline/
COPY render/src/dayline/backend/alembic /srv/dayline/alembic
COPY render/src/dayline/backend/seed /srv/dayline/seed

COPY render/Caddyfile /etc/caddy/Caddyfile
COPY render/supervisord.conf /etc/supervisord.conf
COPY render/bin /opt/bin
RUN chmod 755 /opt/bin/*

USER app
EXPOSE 10000
HEALTHCHECK --interval=30s --timeout=6s --start-period=90s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/health', timeout=5).status == 200 else 1)"
CMD ["/opt/venv-supervisor/bin/supervisord", "-c", "/etc/supervisord.conf"]
