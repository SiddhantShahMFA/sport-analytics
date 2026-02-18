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

# ── Diagnostics ──────────────────────────────────────────────────────

diagnose_bench_state() {
    log "=== Bench state diagnostics ==="
    log "BENCH_DIR=${BENCH_DIR}"

    if [[ -f /home/frappe/.build-complete ]]; then
        log "Docker build marker: FOUND (image was pre-built)"
    else
        log "Docker build marker: NOT FOUND (image needs runtime init)"
    fi

    if [[ -d "${BENCH_DIR}" ]]; then
        log "Bench dir exists"
        if [[ -d "${BENCH_DIR}/sites" ]]; then
            log "sites/ exists"
            ls "${BENCH_DIR}/sites/" 2>/dev/null | while read -r item; do log "  sites/${item}"; done
        else
            log "sites/ MISSING"
        fi
        if [[ -d "${BENCH_DIR}/apps" ]]; then
            log "apps/ exists"
            ls "${BENCH_DIR}/apps/" 2>/dev/null | while read -r item; do log "  apps/${item}"; done
        else
            log "apps/ MISSING"
        fi
        if [[ -f "${BENCH_DIR}/sites/assets/assets.json" ]]; then
            log "assets.json exists ($(wc -c < "${BENCH_DIR}/sites/assets/assets.json") bytes)"
        else
            log "assets.json MISSING"
        fi
    else
        log "Bench dir MISSING entirely"
    fi
    log "=== End diagnostics ==="
}

# ── bench / app bootstrapping ────────────────────────────────────────

ensure_bench() {
    if [[ -f /home/frappe/.build-complete ]]; then
        log "Pre-built bench detected (Docker build marker found). Skipping bench init."
        return
    fi

    if [[ -d "${BENCH_DIR}/sites" && -f "${BENCH_DIR}/sites/apps.txt" ]]; then
        log "Bench already exists at ${BENCH_DIR}"
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

    if [[ -f apps/insights/frontend/package.json ]]; then
        if [[ ! -d apps/insights/frontend/node_modules ]]; then
            log "Installing Insights frontend dependencies"
            cd apps/insights/frontend && (yarn install --frozen-lockfile 2>/dev/null || yarn install)
            cd "${BENCH_DIR}"
        fi
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

setup_assets() {
    cd "${BENCH_DIR}"

    mkdir -p sites/assets

    # Ensure asset symlinks exist for each app
    for app_dir in apps/*/; do
        local app_name
        app_name=$(basename "${app_dir}")
        local app_public="${app_dir}${app_name}/public"
        local asset_link="sites/assets/${app_name}"

        if [[ -d "${app_public}" && ! -e "${asset_link}" ]]; then
            ln -s "../../${app_public}" "${asset_link}"
            log "Created asset symlink: ${asset_link} -> ../../${app_public}"
        fi
    done

    # Verify assets.json exists and is non-empty
    if [[ -f sites/assets/assets.json ]]; then
        local size
        size=$(wc -c < sites/assets/assets.json)
        if [[ "${size}" -gt 10 ]]; then
            log "Pre-built assets.json found (${size} bytes)"
            return 0
        fi
    fi

    log "assets.json missing or empty. Attempting runtime build..."
    if ! is_true "${BUILD_ASSETS}"; then
        log "BUILD_ASSETS is off. Building frappe assets only (required for UI)."
    fi

    if bench build --apps frappe 2>&1; then
        log "Frappe runtime asset build succeeded"
    else
        log "WARNING: Frappe asset build failed"
    fi

    if is_true "${BUILD_INSIGHTS_ASSETS:-0}"; then
        if NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384}" bench build --apps insights 2>&1; then
            log "Insights runtime asset build succeeded"
        else
            log "WARNING: Insights asset build failed"
        fi
    fi
}

ensure_assets_manifest() {
    local assets_json="${BENCH_DIR}/sites/assets/assets.json"
    if [[ ! -f "${assets_json}" ]]; then
        log "Creating placeholder assets manifest (no pre-built assets found)"
        mkdir -p "${BENCH_DIR}/sites/assets"
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
export FRAPPE_DB_NAME="${FRAPPE_DB_NAME:-}"

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

diagnose_bench_state
ensure_bench
ensure_insights_app
configure_common
create_or_restore_site
install_and_migrate
setup_assets
ensure_assets_manifest

start_process "$@"
