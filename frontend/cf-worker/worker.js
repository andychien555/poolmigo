/**
 * MySun demo edge worker — serves the static frontend build (Workers Static Assets)
 * to everyone, always; proxies /rpc to the home Mac's tunnel (chain.mysun.dev),
 * which is only reachable while the Mac is on. When the chain is offline the app
 * shows its "cannot reach the vault" state — accepted for the demo.
 */
const CHAIN_ORIGIN = 'https://chain.mysun.dev/';

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);

    if (pathname === '/rpc' || pathname.startsWith('/rpc/')) {
      try {
        return await fetch(new Request(CHAIN_ORIGIN, request));
      } catch {
        return new Response(JSON.stringify({ error: 'local chain offline' }), {
          status: 502,
          headers: { 'content-type': 'application/json' },
        });
      }
    }

    // Everything else is a static asset; unmatched GETs get the SPA shell
    // (not_found_handling is applied by the ASSETS binding).
    return env.ASSETS.fetch(request);
  },
};
