# mysun-demo — edge worker (Cloudflare)

Serves the built frontend (`../dist`) on https://demo.mysun.dev and proxies
`/rpc` to the home tunnel (`chain.mysun.dev`), which is only up while the demo
Mac is online. The public page itself has no dependency on the Mac.

## Deploy

Requires `wrangler login` once on the machine (OAuth, cached on the demo Mac), then from `frontend/`:

    pnpm deploy:demo        # build (tsc + vite) and deploy — cf-worker/deploy.sh

`deploy.sh` cd's here and execs `../node_modules/.bin/wrangler deploy` (wrangler is a devDependency
of `frontend/` — no npx download per run). In CI, set `CLOUDFLARE_API_TOKEN` instead of logging in.

## Notes

- Zone route `demo.mysun.dev/*` intercepts requests at Cloudflare's edge —
  no DNS record is involved; the page is served from the edge, always.
- `binding = "ASSETS"` must stay set or `env.ASSETS` is undefined at runtime.
- `not_found_handling = "single-page-application"` provides the SPA fallback.
- When the Mac is offline, `/rpc` returns 502 `{"error":"local chain offline"}`
  and the frontend renders its "cannot reach" state (accepted for the demo).
