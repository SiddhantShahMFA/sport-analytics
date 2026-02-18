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
    && printf "frappe\ninsights\n" > sites/apps.txt \
    && rm -rf /tmp/insights-src

# ── 3. Install frontend deps + build all assets at build time ─────────
RUN if [ -f apps/insights/frontend/package.json ]; then \
        cd apps/insights/frontend && yarn install --frozen-lockfile 2>/dev/null || yarn install; \
    fi

RUN bench build --apps frappe \
    && echo "Frappe assets built successfully"

RUN NODE_OPTIONS="--max-old-space-size=1536" bench build --apps insights \
    && echo "Insights assets built successfully" \
    || echo "WARNING: Insights frontend build failed (likely OOM). Frappe assets are still available."

# ── 4. Verify assets and clean up build artifacts to shrink image ─────
RUN echo "=== Asset verification ===" \
    && ls -la sites/assets/ \
    && test -f sites/assets/assets.json \
    && echo "assets.json OK ($(wc -c < sites/assets/assets.json) bytes)" \
    && touch /home/frappe/.build-complete \
    && echo "Build marker created"

RUN rm -rf apps/frappe/.git apps/insights/.git 2>/dev/null || true \
    && rm -rf apps/insights/frontend/node_modules 2>/dev/null || true \
    && rm -rf /home/frappe/.cache /home/frappe/.yarn /tmp/* 2>/dev/null || true \
    && find . -name "*.map" -type f -delete 2>/dev/null || true \
    && find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true \
    && echo "Cleanup complete"

# ── 5. Entrypoint (runtime: configure site, migrate, start) ──────────
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
