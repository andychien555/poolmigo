#!/usr/bin/env bash
# One-shot demo deploy: build the frontend, then ship it to the Cloudflare edge,
# where the `mysun-demo` worker serves https://demo.mysun.dev (static assets + /rpc proxy).
#
# Run from anywhere; typically:
#   cd frontend && pnpm deploy:demo
#
# Prereqs (once per machine): `pnpm install`, and wrangler auth — `pnpm exec wrangler login`
# (OAuth, cached in ~/Library/Preferences/.wrangler) or CLOUDFLARE_API_TOKEN in the environment.
set -euo pipefail
cd "$(dirname "$0")/.." # -> frontend/
pnpm build
cd cf-worker
export WRANGLER_SEND_METRICS=false
exec ../node_modules/.bin/wrangler deploy
