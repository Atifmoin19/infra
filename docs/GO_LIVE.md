# Go live on Oracle Cloud

Follow these steps in order. `<IP>` is the VM's public IP. Run `$` lines on your Mac and `vm$`
lines on the VM.

## 1. Create the VM (Oracle Cloud console)

1. **Compute > Instances > Create instance**
   - Image: **Canonical Ubuntu 24.04** (pick the aarch64 build, not "Minimal" unless you want to).
   - Shape: **Ampere > VM.Standard.A1.Flex**, **4 OCPU / 24 GB** (the whole Always Free allowance).
   - Networking: create/choose a VCN with a **public subnet**, tick **Assign a public IPv4 address**.
   - SSH keys: upload your Mac's `~/.ssh/id_ed25519.pub`.
   - Boot volume: 50–100 GB (200 GB total is free).
2. **"Out of capacity"?** Try another Availability Domain (AD-1/2/3) in the same form, retry at
   off-peak hours, or try 2 OCPU / 12 GB first and resize later. Converting the account to
   **Pay As You Go** (still $0 within Always Free limits; set a budget alert) usually fixes
   capacity immediately. Your home region can't be changed, so this matters most in busy regions
   like Mumbai/Hyderabad.
3. Optional but recommended: **Networking > Reserved public IPs**. Reserve one and attach it to
   the instance's VNIC, so the IP survives if the instance is recreated.

## 2. Open ports 80/443

- **VCN security list** (Networking > VCN > Security Lists > Default): add ingress rules from
  `0.0.0.0/0`: **TCP 80**, **TCP 443**, **UDP 443** (HTTP/3). Leave 22 as it is.
- **On the instance itself**: `bootstrap-vm.sh` (step 4) deletes Oracle's iptables REJECT rule
  and enables ufw with 22, 80/tcp, 443/tcp and 443/udp open.

## 3. DNS (GoDaddy)

In **fullstackcity.in > DNS > Add record**, add Type **A**, Name **api**, Value **`<IP>`**, TTL 600.
Check it with `$ dig +short api.fullstackcity.in` (it should print `<IP>`).

## 4. Bootstrap

```sh
$ scp ~/Projects/personal/infra/scripts/bootstrap-vm.sh ubuntu@<IP>:
$ ssh ubuntu@<IP> 'sudo bash bootstrap-vm.sh'
```

The script installs Docker and compose, creates the `deploy` user (your SSH key is copied to it),
and sets up ufw, fail2ban, unattended-upgrades, 2G swap, log limits and `/srv/src`. It is safe
to re-run.

## 5. Clone the repos (as `deploy`)

```sh
$ ssh deploy@<IP>
```

Public repos can use `https://github.com/...` URLs directly. For private repos, give each repo
its own **read-only deploy key** (GitHub allows one key per repo):

```sh
vm$ for r in infra portfolio expense dayline; do ssh-keygen -t ed25519 -N '' -C "vm-$r" -f ~/.ssh/gh_$r; done
vm$ cat >> ~/.ssh/config <<'CFG'
Host gh-infra
  HostName github.com
  IdentityFile ~/.ssh/gh_infra
Host gh-portfolio
  HostName github.com
  IdentityFile ~/.ssh/gh_portfolio
Host gh-expense
  HostName github.com
  IdentityFile ~/.ssh/gh_expense
Host gh-dayline
  HostName github.com
  IdentityFile ~/.ssh/gh_dayline
CFG
vm$ cat ~/.ssh/gh_*.pub   # add each to its repo: Settings > Deploy keys (read-only)
vm$ ssh-keyscan github.com >> ~/.ssh/known_hosts
```

```sh
vm$ git clone git@gh-infra:Atifmoin19/infra.git /srv/infra
vm$ git clone git@gh-portfolio:Atifmoin19/NextPortfolio-Backend.git /srv/src/portfolio
vm$ git clone -b revive git@gh-expense:Atifmoin19/ExpenseTrackerBE.git /srv/src/expense
vm$ git clone -b master git@gh-dayline:Atifmoin19/<dayline-repo>.git /srv/src/dayline   # repo root; the API is in backend/
vm$ sudo install -d -o 70 -g 70 /srv/infra/backups /srv/infra/backups/expense /srv/infra/backups/dayline   # backup runs as uid 70
```

## 6. Env files and secrets

```sh
vm$ cd /srv/infra
vm$ cp .env.vm.example .env                      # compose paths + prod Caddyfile
vm$ for f in portfolio expense expense-db dayline dayline-db dayline-redis backup; do cp env/$f.env.example env/$f.env; done
vm$ chmod 600 env/*.env
```

Generate the values:

```sh
vm$ openssl rand -hex 32     # each JWT_SECRET (a different one per service)
vm$ openssl rand -hex 24     # DB password (hex, so it is safe inside a URL)
# Portfolio admin password hash:
vm$ docker run --rm python:3.12-slim sh -c "pip -q install passlib bcrypt==4.0.1 2>/dev/null && \
      python -c \"from passlib.context import CryptContext; print(CryptContext(schemes=['bcrypt']).hash('YOUR-PASSWORD'))\""
```

| File | Fill in |
|---|---|
| `env/portfolio.env` | `ADMIN_ID`, `ADMIN_PASSWORD_HASH`, `JWT_SECRET`, `GEMINI_API_KEY` (+`_2`), `RESEND_API_KEY`, `CONTACT_NOTIFY_EMAIL`, `CONTACT_FROM_EMAIL`; keep `BACKEND_PUBLIC_URL=https://api.fullstackcity.in/portfolio`; `ALLOWED_ORIGINS` (see section 9) |
| `env/expense-db.env` | `POSTGRES_PASSWORD` = the DB password |
| `env/expense.env` | `DATABASE_URL=postgresql://expense:<DB password>@expense-db:5432/expense`, `JWT_SECRET`, `ENV=production`, `ALLOWED_ORIGINS`, `DEMO_MODE_ENABLED=true`. Optional: EmailJS, Google, VAPID (reuse the **same** VAPID keys as today or existing push subscriptions break), S3 |
| `env/dayline-db.env` | `POSTGRES_PASSWORD` = a second DB password |
| `env/dayline-redis.env` | `REDIS_PASSWORD` = `openssl rand -hex 24` |
| `env/dayline.env` | `DATABASE_URL=postgresql://dayline:<DB password>@dayline-db:5432/dayline`, `REDIS_PASSWORD` (same as above), `FRONTEND_ORIGIN`, `FRONTEND_APP_URL`, `ENVIRONMENT=production`, `DEMO_MODE_ENABLED=true`, `DEMO_IP_SALT` (`openssl rand -hex 32`). Optional: SMTP, Slack, VAPID, Sentry, Gemini, OIDC. **Leave unused keys commented out, not blank** (`EMAIL_PORT=` crashes the app) |
| `env/backup.env` | `BACKUP_EXPENSE_URL` = expense `DATABASE_URL`; `BACKUP_DAYLINE_URL` = dayline `DATABASE_URL` |

Copy the Firebase service-account file from your Mac:

```sh
$ scp ~/Projects/personal/NextPortfolio/Backend/firebase-service-account.json \
      deploy@<IP>:/srv/infra/secrets/portfolio/
vm$ chmod 644 /srv/infra/secrets/portfolio/firebase-service-account.json   # container uid 10001 must read it
```

**Existing expense data (Neon).** If you want to keep it, move it before you switch the frontend:
```sh
vm$ docker compose up -d expense-db
vm$ docker run --rm postgres:16-alpine pg_dump -Fc --no-owner "<NEON_DATABASE_URL>" > /tmp/neon.dump
vm$ docker compose exec -T expense-db sh -c 'pg_restore --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < /tmp/neon.dump
```
(Alembic then sees the schema is already at head and does nothing.)

## 7. First start

```sh
vm$ cd /srv/infra && docker compose up -d --build
vm$ docker compose ps                  # all services should show (healthy) within about a minute
vm$ docker compose logs -f caddy       # watch for "certificate obtained successfully"
```

## 8. Verify

```sh
$ curl -i https://api.fullstackcity.in/portfolio/health   # 200 {"status":"ok"}
$ curl -i https://api.fullstackcity.in/expense/health     # 200 {"status":"ok","env":"production"}
$ curl -s -X POST https://api.fullstackcity.in/expense/api/v1/auth/demo | head -c 120
$ curl -i https://api.fullstackcity.in/dayline/health      # 200 {"status":"healthy","db":true}
vm$ docker compose exec dayline-worker celery -A celery_app.celery_app inspect ping   # -> pong
vm$ docker compose exec backup /bin/sh /opt/backup/backup.sh once && ls -lh backups/expense
```

## 9. Frontends (Vercel > Project > Settings > Environment Variables, then Redeploy)

**Portfolio** (`NextPortfolio/Frontend`): keep the `VITE_FIREBASE_*` values you have now and set:
```
VITE_API_BASE_URL=https://api.fullstackcity.in/portfolio
```

**All Square** (`ExpenseTrackerFE`):
```
VITE_BASE_URL=https://api.fullstackcity.in/expense
VITE_APP_ENV=production
VITE_DEMO_ENABLED=true
VITE_GOOGLE_CLIENT_ID=<same as backend GOOGLE_CLIENT_ID, or blank>
VITE_VAPID_PUBLIC_KEY=<same as backend VAPID_PUBLIC_KEY, or blank>
```

**Dayline** (`taskboard/frontend`). The WebSocket URL is derived from this value (`wss://.../dayline/ws`), so there is no separate variable:
```
VITE_APP_BASE_URL=https://api.fullstackcity.in/dayline
VITE_APP_ENV=PROD
VITE_DEMO_ENABLED=true
VITE_BUSINESS_TZ=Asia/Kolkata
VITE_GITHUB_URL=https://github.com/Atifmoin19
```

**CORS on the API side.** Use exact origins, comma-separated, with no trailing slash. Include
every domain the browser actually loads the app from, such as custom domains or
`*.vercel.app` production URLs (preview URLs change on every deploy, so add one only to test it):
```
# env/portfolio.env
ALLOWED_ORIGINS=https://portfolio.fullstackcity.in,https://portfolio-henna-three-70.vercel.app
# env/expense.env
ALLOWED_ORIGINS=https://expense-tracker-fe-xi.vercel.app
# env/dayline.env (localhost is always allowed by the app)
FRONTEND_ORIGIN=https://<dayline-frontend>.vercel.app
FRONTEND_APP_URL=https://<dayline-frontend>.vercel.app/
```
After changing these, run `vm$ docker compose up -d portfolio-api expense-api dayline-api dayline-worker dayline-beat`. Env changes need
`up -d`, not just a restart.

## 10. GitHub Actions deploys

1. Push `infra` to GitHub (a private repo is fine).
2. On your Mac, create a deploy key that can **only** run `deploy.sh`:
   ```sh
   $ ssh-keygen -t ed25519 -N '' -C gha-deploy -f ~/.ssh/gha_deploy
   $ echo "command=\"/srv/infra/scripts/deploy.sh --from-ssh\",restrict $(cat ~/.ssh/gha_deploy.pub)" \
       | ssh deploy@<IP> 'cat >> ~/.ssh/authorized_keys'
   ```
3. Pin the host key. Run `$ ssh-keyscan -t ed25519 <IP>` and check that its fingerprint matches
   `vm$ ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
4. In the infra repo, open **Settings > Secrets and variables > Actions** (or the `production`
   environment) and add:
   - `VM_HOST` = `<IP>` (use the same host string you passed to ssh-keyscan)
   - `VM_USER` = `deploy`
   - `VM_SSH_KEY` = contents of `~/.ssh/gha_deploy` (the private key)
   - `VM_KNOWN_HOSTS` = the `ssh-keyscan` output line
5. Test it: **Actions > Deploy > Run workflow > portfolio**.
6. To deploy automatically on push from each service repo, see "Auto-deploy from a service repo"
   in `README.md`.

To deploy by hand on the VM, run `vm$ /srv/infra/scripts/deploy.sh expense` (or `portfolio`, `dayline`, `caddy`; `dayline` redeploys the api, worker and beat together). It pulls the
latest code, builds, waits for the service to be healthy, and rolls back to the previous image
if it isn't.

## 11. After cut-over

- Suspend the Render services once both frontends work against the new API.
- Copy `backups/` off the VM on a schedule (e.g. rclone to OCI Object Storage / Google Drive).
