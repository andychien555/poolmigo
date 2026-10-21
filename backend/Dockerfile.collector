# syntax=docker/dockerfile:1
#
# Multi-stage build for the NAV/fee snapshot collector (Railway service `mysun-analytics`).
# BUILD CONTEXT = the REPO ROOT (unlike Dockerfile, the keeper image, whose context is backend/
# alone): the collector reads the chain registry at runtime, so it ships `shared/` read-only.
#   docker build -f backend/Dockerfile.collector -t mysun-collect .
#
# Read-only service: no key files, no secrets. DATA_DIR is meant to be a mounted volume so the
# JSONL history survives deploys/restarts (Railway volumes).

# ---------------------------------------------------------------------------------------------
FROM node:20-alpine AS deps
WORKDIR /app
RUN npm install -g pnpm@12.5.1
COPY backend/package.json backend/pnpm-lock.yaml backend/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# ---------------------------------------------------------------------------------------------
FROM deps AS build
WORKDIR /app
COPY backend/package.json backend/tsconfig.json backend/tsconfig.build.json ./
COPY backend/src ./src
RUN pnpm run build

# ---------------------------------------------------------------------------------------------
FROM node:20-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

RUN npm install -g pnpm@12.5.1
COPY backend/package.json backend/pnpm-lock.yaml backend/pnpm-workspace.yaml ./
RUN pnpm install --prod --frozen-lockfile && pnpm store prune

COPY --from=build /app/dist ./dist
COPY shared ./shared

# The JSONL history: mount a volume here (Railway: mount path /data).
ENV REGISTRY_DIR=/app/shared \
    DATA_DIR=/data \
    PORT=8080 \
    COLLECT_INTERVAL_MIN=60 \
    LOG_LEVEL=info

EXPOSE 8080

COPY backend/entrypoint-collector.sh /usr/local/bin/entrypoint-collector.sh
RUN chmod +x /usr/local/bin/entrypoint-collector.sh
CMD ["/usr/local/bin/entrypoint-collector.sh"]