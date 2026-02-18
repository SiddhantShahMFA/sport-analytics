# Railway Deployment (Docker)

## Architecture

Assets (CSS/JS bundles for both Frappe and Insights) are **pre-built inside the Docker image** at build time.
At runtime, the entrypoint only configures the site, runs migrations, and starts processes — no `bench init` or `bench build`.

Files:

- `Dockerfile` — multi-step build: bench init → app install → asset build
- `docker/railway-entrypoint.sh` — runtime: configure DB/Redis, create/restore site, migrate, start
- `railway.toml` — Railway build + deploy config

## 1) Railway Services

Create one Railway project with these services:

| Service | Type | Notes |
|---------|------|-------|
| `insights-web` | Docker deploy (this repo) | Runs everything via `APP_ROLE=all` |
| `dbmariadb` | Docker image: `mariadb:10.8` | External DB service |
| `Redis` | Railway plugin | Shared cache/queue/socketio |

Single-service mode (`APP_ROLE=all`) runs web + worker + scheduler + socketio in one container.
This is the recommended setup for personal/client testing.

## 2) Required Environment Variables

### insights-web service

**Core:**
```
FRAPPE_SITE=insights-web-production.up.railway.app   # your actual Railway domain (hostname only, no https://)
ADMIN_PASSWORD=<strong-admin-password>
APP_ROLE=all
```

**Database (wire from dbmariadb):**
```
FRAPPE_DB_HOST=${{dbmariadb.RAILWAY_PRIVATE_DOMAIN}}
FRAPPE_DB_PORT=3306
FRAPPE_DB_USER=root
FRAPPE_DB_PASSWORD=${{dbmariadb.MARIADB_ROOT_PASSWORD}}
FRAPPE_DB_NAME=insights_site
```

**Redis (wire from Redis plugin):**
```
FRAPPE_REDIS_CACHE=${{Redis.REDIS_URL}}
FRAPPE_REDIS_QUEUE=${{Redis.REDIS_URL}}
FRAPPE_REDIS_SOCKETIO=${{Redis.REDIS_URL}}
```

**Optional overrides (defaults are fine for most setups):**
```
BUILD_ASSETS=0              # assets are pre-built in image; set to 1 only to force runtime rebuild
INSTALL_INSIGHTS_APP=1      # install insights on site if not already installed
RUN_MIGRATIONS=1            # auto-migrate on startup
ALLOW_SITE_CREATION=1       # create site if database doesn't exist yet
```

### dbmariadb service

Set these on the `dbmariadb` service (Docker image: `mariadb:10.8`):
```
MARIADB_ROOT_PASSWORD=<strong-root-password>
MARIADB_CHARACTER_SET_SERVER=utf8mb4
MARIADB_COLLATION_SERVER=utf8mb4_unicode_ci
```

## 3) Deploy

1. Push code to the branch connected to `insights-web`.
2. Railway builds the Docker image (bench init + asset build happen here).
3. On startup, the entrypoint:
   - Waits for DB and Redis
   - Writes `site_config.json` from env vars
   - Creates site if DB is empty, or restores config if DB already exists (safe across redeploys)
   - Installs insights app + runs migrations
   - Starts all processes on Railway's `$PORT`

First deploy takes longer (image build includes `bench init` and `bench build`).
Subsequent deploys are faster due to Docker layer caching.

## 4) Domain and Access

1. Attach Railway-generated domain (or custom domain) to `insights-web`.
2. Set `FRAPPE_SITE` to the **exact hostname** (no `https://`, no path, no trailing slash).
3. URLs:
   - Login: `https://<domain>/app`
   - Insights: `https://<domain>/app/insights`

## 5) Create Client Test Users

From Railway service shell (or `railway run`):

```bash
bench --site "$FRAPPE_SITE" add-user client1@example.com --first-name Client --last-name One --password "ChangeMe#123" --user-type "System User" --add-role "Insights User"
bench --site "$FRAPPE_SITE" add-user client2@example.com --first-name Client --last-name Two --password "ChangeMe#123" --user-type "System User" --add-role "Insights User"
bench --site "$FRAPPE_SITE" add-user client3@example.com --first-name Client --last-name Three --password "ChangeMe#123" --user-type "System User" --add-role "Insights User"
```

Have each user change their password after first login. Do not assign `System Manager` role unless required.

## 6) Post-Deploy Checks

- `GET /api/method/ping` → 200
- `/app` loads with styled login page (CSS/JS assets present)
- `/app/insights` opens after login
- Background jobs running (check via `/app/background_jobs`)

## 7) Cleanup (from previous multi-service attempt)

Delete these leftover services if they still exist:
- `mariadb` (replaced by `dbmariadb`)
- `insights-worker`
- `insights-schedule`
- `insights-socketio`

## Troubleshooting

**502 after deploy**: Check Railway logs — entrypoint may still be running site creation/migration. Wait for "Starting all processes" log line.

**Assets still broken**: Verify build logs show successful `bench build --apps frappe` and `bench build --apps insights`. If insights build fails at build time, check Node.js memory — the Dockerfile sets `--max-old-space-size=1536`.

**Site created fresh on every deploy**: Ensure `FRAPPE_DB_NAME` is set and matches across deploys. The entrypoint checks for the database by name to decide whether to create or restore.
