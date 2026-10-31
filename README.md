# infra — shared backend server

All backends for fullstackcity.in run as Docker containers on one Oracle Cloud Always Free VM
(ARM64, Ubuntu) behind Caddy at **api.fullstackcity.in**, routed by path. Frontends live on Vercel.

| Path          | Service          | Source                                   |
|---------------|------------------|------------------------------------------|
| `/portfolio/` | `portfolio-api`  | `../NextPortfolio/Backend` (FastAPI)     |
| `/expense/`   | `expense-api`    | `../ExpenseTrackerBE` (All Square, FastAPI + Postgres 16 `expense-db`) |
| `/taskboard/` | _todo (part 3)_  |                                          |

Caddy uses `handle_path`, which strips the prefix: `GET /portfolio/health` reaches the app as
`GET /health`. App code is unchanged; uvicorn runs with `--root-path /portfolio` so `/docs`
and the OpenAPI URL are generated correctly.

## Layout

```
infra/                         # this repo; source repos are checked out as siblings
  docker-compose.yml
  caddy/Dockerfile             # caddy:2.8-alpine running as non-root (uid 10000)
  caddy/Caddyfile              # prod: api.fullstackcity.in, automatic HTTPS
  caddy/Caddyfile.local        # local: http://localhost, no TLS
  caddy/routes.caddy           # shared path routes, imported by both Caddyfiles
  services/<svc>/Dockerfile    # override Dockerfiles (non-root, healthcheck, prod server)
  env/<svc>.env.example        # committed, placeholder keys only
  env/<svc>.env                # real values, gitignored
  secrets/<svc>/...            # secret files, gitignored, bind-mounted read-only
  backup/backup.sh             # nightly pg_dump loop used by the `backup` service
  backups/<db>/                # dumps, gitignored
../NextPortfolio/Backend       # build context for portfolio-api
../ExpenseTrackerBE            # build context for expense-api (branch `revive`)
```

The build contexts are relative (`../NextPortfolio/Backend`), so on the VM clone the source
repos next to `infra/` with the same directory names.

## Run locally

```sh
cp env/portfolio.env.example env/portfolio.env        # fill in values
cp /path/to/firebase-service-account.json secrets/portfolio/
cp env/expense.env.example env/expense.env              # DB password must match the next two
cp env/expense-db.env.example env/expense-db.env
cp env/backup.env.example env/backup.env
CADDYFILE=Caddyfile.local docker compose up -d --build
curl -i http://localhost/portfolio/health             # HTTP/1.1 200 OK {"status":"ok"}
curl -i http://localhost/expense/health               # HTTP/1.1 200 OK
docker compose down
```

Port 80 on the host must be free. Only Caddy publishes ports (80, 443); backends are reachable
only through Caddy.

## Run in production (VM)

```sh
docker compose up -d --build      # uses caddy/Caddyfile -> api.fullstackcity.in
```

DNS `A api.fullstackcity.in -> <VM public IP>` must exist and ports 80/443 must be open in both the
OCI security list and the VM firewall (iptables/ufw) before Caddy can get a certificate.
Certificates persist in the `caddy_data` volume.

## Expense (All Square)

- `expense-api` runs `alembic upgrade head` on every start, then uvicorn with
  `--root-path /expense`. Set `DEMO_MODE_ENABLED=true` to enable `POST /expense/api/v1/auth/demo`.
- `expense-db` (postgres:16-alpine, non-root, volume `expense_db_data`) is only on `expense_net`
  (`internal: true`): no internet, and only `expense-api` and `backup` can reach it. The API
  reaches Caddy and the internet via `expense_edge`.
- Client IP: Caddy overwrites `X-Forwarded-For` with the real peer address (client-supplied values
  are dropped), and uvicorn `--proxy-headers` maps it to `request.client.host`, so the per-IP demo
  limit counts real visitors, not Caddy.
- `POSTGRES_PASSWORD` only applies when the volume is first created. To rotate it later, run
  `ALTER ROLE` inside the DB and update `env/expense.env` and `env/backup.env`.

## Backups

The `backup` service (postgres:16-alpine, so `pg_dump` matches the server version) dumps every
`BACKUP_<NAME>_URL` in `env/backup.env` daily at `BACKUP_AT` (UTC; default 21:00 = 02:30 IST)
to `./backups/<name>/<name>-YYYYmmdd-HHMMSS.dump` (custom format) and deletes dumps older than
`BACKUP_KEEP_DAYS` (7).

```sh
docker compose exec backup /bin/sh /backup.sh once            # back up now
ls -lh backups/expense/
docker compose exec -T backup pg_restore --list /backups/expense/<file>.dump   # inspect

# Restore (replaces existing objects). Stop the API first so nothing writes meanwhile.
docker compose stop expense-api
docker compose exec -T expense-db sh -c 'pg_restore --clean --if-exists --no-owner \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < backups/expense/<file>.dump
docker compose start expense-api
```

On the Linux VM, the container runs as uid 70, so: `sudo chown -R 70:70 backups/`.
Copy `backups/` off the VM too (e.g. rclone to object storage); a dump on the same disk
doesn't help if the VM is lost.

Adding a DB (e.g. taskboard): add `BACKUP_TASKBOARD_URL=...@taskboard-db:5432/...` to
`env/backup.env`, `touch backups/taskboard/.gitkeep`, and add `taskboard_net` to the `backup`
service's `networks`.

## Secrets and env

- Non-file config goes in `env/<svc>.env` (gitignored). Keep `env/<svc>.env.example` in sync with
  the keys the service reads.
- Secret files go in `secrets/<svc>/` (gitignored) and are bind-mounted read-only; they are never
  `COPY`'d into an image. Override Dockerfiles copy only the files they need (e.g. `app/`).
- On Linux the container user must be able to read the mounted file:
  `chmod 644 secrets/portfolio/firebase-service-account.json` (or `chown 10001`).
- See `secrets/README.md` for the per-service list.

## Add a new service

1. If the repo's own Dockerfile runs as root, lacks a healthcheck, or runs a dev server, add
   `services/<svc>/Dockerfile` here instead of editing the source repo.
2. Add `env/<svc>.env.example` listing every key from the app's config, and `secrets/<svc>/` if
   it needs secret files.
3. In `docker-compose.yml`: add the service (use `<<: *hardening`, `mem_limit`, `read_only`,
   a `healthcheck` if the image lacks one, **no `ports:`**), a new `<svc>_net` network, and add
   that network to `caddy`. If it has a database, follow the expense pattern: the DB only on an
   `internal: true` `<svc>_net`, and the API also on a `<svc>_edge` shared with Caddy.
4. In `caddy/routes.caddy`: add `handle_path /<svc>/* { reverse_proxy <svc>-api:<port> }` above
   the catch-all `handle`.
5. `CADDYFILE=Caddyfile.local docker compose up -d --build` and `curl http://localhost/<svc>/health`.

## Hardening defaults

Every container: `restart: unless-stopped`, non-root user, `cap_drop: ALL` (Caddy adds back only
`NET_BIND_SERVICE`), `no-new-privileges`, read-only root fs with a `/tmp` tmpfs, a memory limit,
log rotation (3 x 10 MB), and a healthcheck.

## ARM64

The VM is ARM64 (Ampere A1). Images are built on the host where they run, so on the VM they build
natively for `linux/arm64`. All portfolio dependencies (grpcio, cryptography, bcrypt, uvloop,
httptools, pydantic-core) ship manylinux aarch64 wheels, so no compiler is needed.
To cross-build on an x86 machine: `docker buildx build --platform linux/arm64 ...`.
