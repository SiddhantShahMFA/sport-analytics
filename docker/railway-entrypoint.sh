#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[%s] [railway-entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

is_true() {
    case "${1:-}" in
        1 | true | TRUE | yes | YES | on | ON) return 0 ;;
        *) return 1 ;;
    esac
}

set_env_if_missing() {
    local target_key="$1"
    local fallback_key="$2"
    local fallback_value="${!fallback_key:-}"
    if [[ -z "${!target_key:-}" && -n "${fallback_value}" ]]; then
        export "${target_key}=${fallback_value}"
    fi
}

bench_cmd() {
    cd "${BENCH_DIR}"
    bench "$@"
}

wait_for_tcp() {
    local host="$1"
    local port="$2"
    local name="$3"
    local retries="${4:-60}"
    local sleep_seconds="${5:-2}"

    for _ in $(seq 1 "${retries}"); do
        if nc -z "${host}" "${port}" >/dev/null 2>&1; then
            log "${name} is reachable at ${host}:${port}"
            return 0
        fi
        sleep "${sleep_seconds}"
    done

    log "Timed out waiting for ${name} at ${host}:${port}"
    return 1
}

# ── bench / app bootstrapping (mostly no-ops when image is pre-built) ──

ensure_bench() {
    if [[ -d "${BENCH_DIR}/sites" && -f "${BENCH_DIR}/sites/apps.txt" ]]; then
        log "Bench already exists at ${BENCH_DIR} (pre-built image)"
        return
    fi

    if [[ -d "${BENCH_DIR}" ]]; then
        rm -rf "${BENCH_DIR}"
    fi

    log "Initializing new bench at ${BENCH_DIR} (branch: ${FRAPPE_BRANCH}, python: ${FRAPPE_PYTHON})"
    bench init --skip-redis-config-generation --skip-assets --frappe-branch "${FRAPPE_BRANCH}" --python "${FRAPPE_PYTHON}" "${BENCH_DIR}"
}

ensure_insights_app() {
    cd "${BENCH_DIR}"

    if [[ -d "${BENCH_DIR}/apps/insights" ]]; then
        log "Insights app already present in bench"
    elif [[ -d "${APP_SOURCE_PATH}" ]]; then
        log "Copying Insights app from ${APP_SOURCE_PATH}"
        mkdir -p "${BENCH_DIR}/apps"
        cp -a "${APP_SOURCE_PATH}" "${BENCH_DIR}/apps/insights"
    else
        log "WARNING: Insights app source path not found: ${APP_SOURCE_PATH}"
        return 1
    fi

    if ! "${BENCH_DIR}/env/bin/python" -c "import insights" >/dev/null 2>&1; then
        log "Installing Insights app into bench environment"
        "${BENCH_DIR}/env/bin/pip" install --quiet --upgrade -e "${BENCH_DIR}/apps/insights"
    fi

    mkdir -p "${BENCH_DIR}/sites"
    if ! grep -qx 'insights' "${BENCH_DIR}/sites/apps.txt" 2>/dev/null; then
        printf "frappe\ninsights\n" > "${BENCH_DIR}/sites/apps.txt"
    fi
}

# ── DB/Redis configuration ─────────────────────────────────────────────

configure_common() {
    cd "${BENCH_DIR}"

    log "Applying DB/Redis configuration"
    bench set-mariadb-host "${FRAPPE_DB_HOST}"
    bench set-redis-cache-host "${FRAPPE_REDIS_CACHE}"
    bench set-redis-queue-host "${FRAPPE_REDIS_QUEUE}"
    bench set-redis-socketio-host "${FRAPPE_REDIS_SOCKETIO}"

    if [[ -f "${BENCH_DIR}/Procfile" ]]; then
        sed -i '/^redis_cache:/d;/^redis_queue:/d;/^watch:/d' "${BENCH_DIR}/Procfile" || true
    fi
}

# ── Site management (safe across ephemeral filesystem) ─────────────────

db_exists() {
    "${BENCH_DIR}/env/bin/python" -c "
import pymysql, os
try:
    conn = pymysql.connect(
        host=os.environ['FRAPPE_DB_HOST'],
        port=int(os.environ['FRAPPE_DB_PORT']),
        user=os.environ.get('DB_ROOT_USER', 'root'),
        password=os.environ.get('DB_ROOT_PASSWORD', ''),
    )
    cur = conn.cursor()
    cur.execute('SHOW DATABASES LIKE %s', (os.environ['FRAPPE_DB_NAME'],))
    result = cur.fetchone()
    conn.close()
    exit(0 if result else 1)
except Exception as e:
    print(f'DB check failed: {e}')
    exit(1)
" 2>/dev/null
}

write_site_config() {
    local site_dir="${BENCH_DIR}/sites/${SITE_NAME}"
    mkdir -p "${site_dir}"

    "${BENCH_DIR}/env/bin/python" -c "
import json, os
config = {
    'db_name': os.environ.get('FRAPPE_DB_NAME', '_' + os.environ['SITE_NAME'].replace('.', '_').replace('-', '_')),
    'db_password': os.environ.get('FRAPPE_DB_PASSWORD', ''),
    'db_type': 'mariadb',
    'db_host': os.environ.get('FRAPPE_DB_HOST', 'localhost'),
    'db_port': int(os.environ.get('FRAPPE_DB_PORT', 3306)),
}
path = '${site_dir}/site_config.json'
if os.path.exists(path):
    with open(path) as f:
        existing = json.load(f)
    existing.update(config)
    config = existing
with open(path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
"
    log "Wrote site_config.json for ${SITE_NAME}"
}

create_or_restore_site() {
    cd "${BENCH_DIR}"

    write_site_config

    if db_exists; then
        log "Database '${FRAPPE_DB_NAME}' already exists — restoring site locally (no data loss)"
        return 0
    fi

    if ! is_true "${ALLOW_SITE_CREATION}"; then
        log "Site ${SITE_NAME} is missing and ALLOW_SITE_CREATION is disabled"
        return 1
    fi

    log "Creating new site ${SITE_NAME} (fresh database)"
    bench new-site "${SITE_NAME}" \
        --force \
        --mariadb-root-username "${DB_ROOT_USER}" \
        --mariadb-root-password "${DB_ROOT_PASSWORD}" \
        --admin-password "${ADMIN_PASSWORD}" \
        --no-mariadb-socket
}

install_and_migrate() {
    cd "${BENCH_DIR}"

    if is_true "${INSTALL_INSIGHTS_APP}"; then
        if ! bench --site "${SITE_NAME}" list-apps 2>/dev/null | grep -qx 'insights'; then
            log "Installing insights app on ${SITE_NAME}"
            bench --site "${SITE_NAME}" install-app insights
        fi
    fi

    if is_true "${RUN_MIGRATIONS}"; then
        log "Running migrations on ${SITE_NAME}"
        bench --site "${SITE_NAME}" migrate
    fi

    bench --site "${SITE_NAME}" set-config developer_mode 1 || true
    bench --site "${SITE_NAME}" set-config mute_emails 1 || true
    bench --site "${SITE_NAME}" clear-cache || true
}

# ── Asset management ───────────────────────────────────────────────────

ensure_assets() {
    cd "${BENCH_DIR}"

    if ! is_true "${BUILD_ASSETS}"; then
        log "Skipping runtime asset build (BUILD_ASSETS=${BUILD_ASSETS}; assets are pre-built in Docker image)"
        return 0
    fi

    log "Building frontend assets at runtime"
    if ! bench build --apps frappe; then
        log "Frappe asset build failed"
        return 1
    fi

    if is_true "${BUILD_INSIGHTS_ASSETS:-0}"; then
        if ! NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384}" bench build --apps insights; then
            log "Insights asset build failed; continuing with Frappe bundles only"
        fi
    fi

    return 0
}

ensure_assets_manifest() {
    local assets_dir="${BENCH_DIR}/sites/assets"
    local assets_json="${assets_dir}/assets.json"
    mkdir -p "${assets_dir}"
    if [[ ! -f "${assets_json}" ]]; then
        log "Creating placeholder assets manifest"
        printf "{}\n" > "${assets_json}"
    fi
}

# ── Process startup ────────────────────────────────────────────────────

start_process() {
    cd "${BENCH_DIR}"

    case "${APP_ROLE}" in
        web)
            log "Starting web process on port ${PORT}"
            exec bench serve --port "${PORT}"
            ;;
        worker)
            log "Starting worker process"
            exec bench worker
            ;;
        schedule)
            log "Starting scheduler process"
            exec bench schedule
            ;;
        socketio)
            log "Starting socketio process"
            exec node apps/frappe/socketio.js
            ;;
        all)
            log "Starting all processes (web on port ${PORT}, worker, scheduler, socketio)"
            bench serve --port "${PORT}" &
            web_pid=$!
            node apps/frappe/socketio.js &
            socketio_pid=$!
            bench schedule &
            schedule_pid=$!
            bench worker &
            worker_pid=$!

            trap 'kill ${web_pid} ${socketio_pid} ${schedule_pid} ${worker_pid} 2>/dev/null || true' EXIT INT TERM
            wait -n "${web_pid}" "${socketio_pid}" "${schedule_pid}" "${worker_pid}"
            exit $?
            ;;
        *)
            log "Unknown APP_ROLE=${APP_ROLE}. Running provided command: $*"
            exec "$@"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════

# Map Railway plugin env vars to Frappe env vars
set_env_if_missing FRAPPE_DB_HOST MYSQLHOST
set_env_if_missing FRAPPE_DB_PORT MYSQLPORT
set_env_if_missing FRAPPE_DB_USER MYSQLUSER
set_env_if_missing FRAPPE_DB_PASSWORD MYSQLPASSWORD
set_env_if_missing FRAPPE_DB_NAME MYSQLDATABASE

set_env_if_missing FRAPPE_REDIS_CACHE REDIS_URL
set_env_if_missing FRAPPE_REDIS_QUEUE REDIS_URL
set_env_if_missing FRAPPE_REDIS_SOCKETIO REDIS_URL

export PORT="${PORT:-8000}"
export FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
export FRAPPE_PYTHON="${FRAPPE_PYTHON:-python3.12}"
export BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
export APP_SOURCE_PATH="${APP_SOURCE_PATH:-/workspace/insights}"
export SITE_NAME="${FRAPPE_SITE:-${SITE_NAME:-insights.localhost}}"
export APP_ROLE="${APP_ROLE:-all}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123}"
export DB_ROOT_USER="${DB_ROOT_USER:-${FRAPPE_DB_USER:-root}}"
export DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-${FRAPPE_DB_PASSWORD:-}}}}"

if [[ -z "${RUN_MIGRATIONS:-}" ]]; then
    if [[ "${APP_ROLE}" == "web" || "${APP_ROLE}" == "all" ]]; then
        RUN_MIGRATIONS="1"
    else
        RUN_MIGRATIONS="0"
    fi
fi

if [[ -z "${ALLOW_SITE_CREATION:-}" ]]; then
    if [[ "${APP_ROLE}" == "web" || "${APP_ROLE}" == "all" ]]; then
        ALLOW_SITE_CREATION="1"
    else
        ALLOW_SITE_CREATION="0"
    fi
fi

if [[ -z "${BUILD_ASSETS:-}" ]]; then
    BUILD_ASSETS="0"
fi

export RUN_MIGRATIONS
export ALLOW_SITE_CREATION
export INSTALL_INSIGHTS_APP="${INSTALL_INSIGHTS_APP:-1}"
export BUILD_ASSETS
export BUILD_INSIGHTS_ASSETS="${BUILD_INSIGHTS_ASSETS:-0}"

required_env=(FRAPPE_DB_HOST FRAPPE_DB_PORT FRAPPE_DB_USER FRAPPE_DB_PASSWORD FRAPPE_DB_NAME FRAPPE_REDIS_CACHE FRAPPE_REDIS_QUEUE FRAPPE_REDIS_SOCKETIO)
for key in "${required_env[@]}"; do
    if [[ -z "${!key:-}" ]]; then
        log "Missing required environment variable: ${key}"
        exit 1
    fi
done

redis_host="$(python3 -c "from urllib.parse import urlparse; import os; u=urlparse(os.environ['FRAPPE_REDIS_CACHE']); print(u.hostname or '')")"
redis_port="$(python3 -c "from urllib.parse import urlparse; import os; u=urlparse(os.environ['FRAPPE_REDIS_CACHE']); print(u.port or 6379)")"

wait_for_tcp "${FRAPPE_DB_HOST}" "${FRAPPE_DB_PORT}" "MariaDB"
wait_for_tcp "${redis_host}" "${redis_port}" "Redis"

ensure_bench
ensure_insights_app
configure_common
create_or_restore_site
install_and_migrate
ensure_assets || true
ensure_assets_manifest

start_process "$@"
