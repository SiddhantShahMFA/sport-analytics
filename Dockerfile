FROM frappe/bench:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe

ARG FRAPPE_BRANCH=version-15
ARG FRAPPE_PYTHON=python3.12

# ── 1. Initialize bench (downloads frappe, creates venv) ──────────────
RUN bench init --skip-redis-config-generation --skip-assets \
    --frappe-branch "${FRAPPE_BRANCH}" --python "${FRAPPE_PYTHON}" \
    /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# ── 2. Copy insights app source into the bench ────────────────────────
COPY --chown=frappe:frappe . /tmp/insights-src
RUN cp -a /tmp/insights-src apps/insights \
    && ./env/bin/pip install --quiet --upgrade -e apps/insights \
    && printf "frappe\ninsights\n" > sites/apps.txt

# ── 3. Install frontend deps + build all assets at build time ─────────
RUN if [ -f apps/insights/frontend/package.json ]; then \
        cd apps/insights/frontend && yarn install --frozen-lockfile 2>/dev/null || yarn install; \
    fi

RUN bench build --apps frappe
RUN NODE_OPTIONS="--max-old-space-size=1536" bench build --apps insights

# ── 4. Entrypoint (runtime: configure site, migrate, start) ──────────
COPY --chown=frappe:frappe docker/railway-entrypoint.sh /workspace/railway-entrypoint.sh
USER root
RUN chmod +x /workspace/railway-entrypoint.sh
USER frappe

WORKDIR /home/frappe

ENV SHELL=/bin/bash \
    BENCH_DIR=/home/frappe/frappe-bench \
    FRAPPE_BRANCH=version-15 \
    FRAPPE_PYTHON=python3.12 \
    SITE_NAME=insights.localhost \
    APP_ROLE=all \
    INSTALL_INSIGHTS_APP=1 \
    BUILD_ASSETS=0

EXPOSE 8000 9000

ENTRYPOINT ["/workspace/railway-entrypoint.sh"]
