# ═══════════════════════════════════════════════════════════════════════
# Stage 1: Builder — bench init, app install, asset compilation
# ═══════════════════════════════════════════════════════════════════════
FROM frappe/bench:latest AS builder

USER frappe
WORKDIR /home/frappe

ARG FRAPPE_BRANCH=version-15
ARG FRAPPE_PYTHON=python3.12

RUN bench init --skip-redis-config-generation --skip-assets \
    --frappe-branch "${FRAPPE_BRANCH}" --python "${FRAPPE_PYTHON}" \
    /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

COPY --chown=frappe:frappe . /tmp/insights-src
RUN cp -a /tmp/insights-src apps/insights \
    && ./env/bin/pip install --quiet --upgrade -e apps/insights \
    && printf "frappe\ninsights\n" > sites/apps.txt \
    && rm -rf /tmp/insights-src

RUN if [ -f apps/insights/frontend/package.json ]; then \
        cd apps/insights/frontend && yarn install --frozen-lockfile 2>/dev/null || yarn install; \
    fi

RUN bench build --apps frappe

RUN NODE_OPTIONS="--max-old-space-size=1536" bench build --apps insights \
    || echo "WARNING: Insights frontend build failed. Frappe assets still available."

# Heavy cleanup while still in the builder stage (won't bloat final image)
RUN rm -rf apps/frappe/.git apps/insights/.git \
    && rm -rf apps/insights/frontend/node_modules \
    && rm -rf apps/frappe/node_modules \
    && rm -rf /home/frappe/.cache /home/frappe/.yarn /home/frappe/.npm \
    && rm -rf /tmp/* \
    && find /home/frappe/frappe-bench -name "*.map" -type f -delete \
    && find /home/frappe/frappe-bench -name "__pycache__" -type d -exec rm -rf {} + \
    && find /home/frappe/frappe-bench -name "*.pyc" -type f -delete \
    && find /home/frappe/frappe-bench -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true

# Resolve asset symlinks into real files so they survive the COPY
RUN cd sites/assets \
    && for link in frappe insights; do \
        if [ -L "$link" ]; then \
            target=$(readlink "$link") \
            && rm "$link" \
            && cp -a "$target" "$link"; \
        fi; \
    done \
    && echo "Asset symlinks resolved to real directories"

RUN test -f sites/assets/assets.json \
    && echo "Assets verified: $(wc -c < sites/assets/assets.json) bytes" \
    && touch /home/frappe/.build-complete

# ═══════════════════════════════════════════════════════════════════════
# Stage 2: Runtime — clean image with only what's needed
# ═══════════════════════════════════════════════════════════════════════
FROM frappe/bench:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe

# Copy the fully built bench (with resolved asset dirs, no .git, no node_modules)
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
COPY --from=builder --chown=frappe:frappe /home/frappe/.build-complete /home/frappe/.build-complete

COPY --chown=frappe:frappe docker/railway-entrypoint.sh /workspace/railway-entrypoint.sh
USER root
RUN chmod +x /workspace/railway-entrypoint.sh
USER frappe

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
