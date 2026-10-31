# Deploy on Render (one free web service)

**Primary hosting.** One Docker web service (`render.yaml` at the repo root) runs three backends
as separate processes. The Oracle VM stack (`docker-compose.yml`, `docs/GO_LIVE.md`) is the
secondary path.

```
Render :$PORT -> Caddy ─┬ /health       -> health.py (200 only if all three apps are healthy)
                        ├ /portfolio/*  -> uvicorn 127.0.0.1:8001  (NextPortfolio-Backend)
                        ├ /expense/*    -> uvicorn 127.0.0.1:8002  (ExpenseTrackerBE; alembic on start)
                        └ /dayline/*    -> uvicorn 127.0.0.1:8003  (dayline/backend; alembic on start,
                                           CELERY_ENABLED=false, no Redis, WebSocket /dayline/ws)
```

- supervisord (`render/supervisord.conf`) restarts any process that dies. `memmon` restarts any
  app that stays above its memory cap. Every log line goes to stdout prefixed with `[app]`.
- Each app has its own venv on Python 3.12 and gets only its own `PREFIX__` variables. Empty
  values are dropped, so the app uses its default.
- Caddy trusts Render's private-range proxy and reads `X-Forwarded-For` right to left, so the
  per-IP demo limits see the real client. Spoofed entries are ignored.
- Render free tier: 512 MB RAM (about 335 MiB used idle), 0.1 CPU, sleeps after 15 min idle
  (expect a cold start of 30–60 s), and an ephemeral disk. All state lives in the external
  Postgres databases.

## Sources: git submodules

| Path | Repo | Branch |
|---|---|---|
| `render/src/portfolio` | Atifmoin19/NextPortfolio-Backend | main |
| `render/src/expense` | Atifmoin19/ExpenseTrackerBE | revive (has the demo; switch to `main` once merged) |
| `render/src/dayline` | Atifmoin19/dayline | master |

```sh
git submodule update --init                 # after cloning infra
git submodule update --remote               # move every submodule to its branch tip
git add render/src && git commit -m "Bump backend sources" && git push   # Render auto-deploys
```

Render clones submodules during the build. Every pinned commit must already be pushed to
GitHub, and if a repo is private, Render's GitHub app needs access to it.

## Setup

1. Create two Postgres databases (e.g. Neon free tier), one for expense and one for Dayline.
   Render's free Postgres expires after 30 days.
2. Render: **New > Blueprint**, pick the infra repo, then fill in the `sync: false` values.
   Optional ones can be left empty.
3. Encode the Firebase key:
   `base64 -i firebase-service-account.json | tr -d '\n' | pbcopy`. Paste the result into
   `PORTFOLIO__FIREBASE_SERVICE_ACCOUNT_B64`.
4. Check `https://<service>.onrender.com/health`. It should return
   `{"status":"ok","services":{...all ok}}`.

## Env vars (Render dashboard; prefix = which app gets it)

| App | Required | Preset in render.yaml | Optional (leave empty if unused) |
|---|---|---|---|
| `PORTFOLIO__` | `ADMIN_ID`, `ADMIN_PASSWORD_HASH`, `GEMINI_API_KEY`, `FIREBASE_SERVICE_ACCOUNT_B64` | `JWT_SECRET` (generated), `JWT_EXPIRE_MINUTES`, `GEMINI_MODEL`, `ALLOWED_ORIGINS`, `BACKEND_PUBLIC_URL`, `CONTACT_FROM_EMAIL`, `CONTACT_EMAILS_PER_DAY` | `GEMINI_API_KEY_2`, `RESEND_API_KEY`, `CONTACT_NOTIFY_EMAIL` |
| `EXPENSE__` | `DATABASE_URL` | `JWT_SECRET` (generated), `JWT_*_TTL_*`, `ENV=production`, `ALLOWED_ORIGINS`, `DEMO_*` | `EMAILJS_*`, `GOOGLE_CLIENT_ID/SECRET`, `VAPID_*`, `AWS_*`, `S3_BUCKET_NAME` |
| `DAYLINE__` | `DATABASE_URL`, `FRONTEND_ORIGIN`, `FRONTEND_APP_URL` | `DEMO_IP_SALT` (generated), `ENVIRONMENT`, `DEMO_*`, `*_INTERVAL_SECONDS`, `BUSINESS_*`, `MAX_OPEN_SESSION_HOURS` | `EMAIL_*`, `DEFAULT_FROM_EMAIL`, `SLACK_WEBHOOK_URL`, `VAPID_*`, `SENTRY_DSN`, `GEMINI_*`, `OIDC_*` (redirect URI: `https://<service>.onrender.com/dayline/auth/sso/callback`) |

If the service name `fullstackcity-api` is taken on Render, update
`PORTFOLIO__BACKEND_PUBLIC_URL` to the real URL. To serve the API at api.fullstackcity.in
instead, add it under **Custom Domains** and point a CNAME at the onrender.com host.

## Frontends (Vercel)

- Portfolio: `VITE_API_BASE_URL=https://<service>.onrender.com/portfolio`
- All Square: `VITE_BASE_URL=https://<service>.onrender.com/expense`, `VITE_DEMO_ENABLED=true`
- Dayline: `VITE_APP_BASE_URL=https://<service>.onrender.com/dayline`, `VITE_DEMO_ENABLED=true`.
  The WebSocket URL is derived from this value.

## Build and run locally

```sh
docker build -f render/Dockerfile -t fsc-api .
docker run --rm -p 10000:10000 --memory=512m -e PORT=10000 \
  -e PORTFOLIO__ADMIN_ID=... -e EXPENSE__DATABASE_URL=... -e DAYLINE__DATABASE_URL=... fsc-api
curl localhost:10000/health
docker exec <id> /opt/venv-supervisor/bin/supervisorctl -c /etc/supervisord.conf status
```

Limitation: all processes run as the same non-root user. An app therefore never *receives*
another app's variables, but a compromised app could still read supervisord's environment
from `/proc`. This is process-level separation, not a security boundary.
