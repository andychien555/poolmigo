# REPORT — frontend: real viem/wagmi wiring for the Poolmigo vault

Scope: `frontend/` only. No git commands run; nothing outside `frontend/` was modified.

## What was built

The prototype's design, brand and product shell are unchanged — all demo flows (deposit, withdraw,
stake, claim, lock, theme, market badge, reset) still work exactly as before. What changed:

1. **Real wallet + chains.** `viem` + `wagmi` + `@tanstack/react-query` added. The fake connect is
   gone: `useConnectWallet()` is the single connect entry point (header, welcome panel, prototype
   deposit card, live cards) and uses wagmi's `injected()` connector. Chains: local Anvil
   (`46630`, `http://127.0.0.1:8547`, labelled "Robinhood Chain (local)", `testnet: true`) and an
   RHC mainnet stub (`4663`, `https://rpc.mainnet.chain.robinhood.com`) for later. When no browser
   wallet exists the button offers a clearly-labelled **demo wallet** instead, so the deck demo still
   runs on a machine with no extension; `?wallet=demo` still forces it. All pages browse fine
   disconnected.

2. **A live vault page (`/live`) where every number is a chain read.** migoLP supply and your balance
   and share %, per-token basket totals with an idle vs in-position split and a "% deployed" bar,
   performance fee, paused state, adapter list with decoded `dex()` / `poolId()` labels and
   per-adapter `position()`, plus the mock-only `deployed(i)` / `harvestable(i)` columns requested
   opportunistically (`allowFailure`, silently absent against a real adapter), and your per-token
   position via `previewRedeem(balanceOf)`. Reads always target the deployment chain, so the page
   works with no wallet or a wallet on the wrong network.

3. **In-kind deposit flow.** Per-token inputs with wallet balances and Max, live `previewDeposit`
   showing the computable shares *and* the exact per-token pull, a slippage tolerance field
   (default 50 bps) driving `minShares = floor(shares × (1 − tol))` clamped so it can never be 0,
   per-token `approve` only where the allowance is short, then `deposit`. Approve → Deposit → Done
   step trail; failures show a decoded custom error; success shows the shares actually minted, read
   from the `Deposited` event in the receipt.

4. **Redeem flow.** migoLP input + Max, live `previewRedeem` breakdown per token, redeem, and the
   amounts actually delivered read from the `Redeemed` event.

5. **Local-only dev tools.** A panel (hidden as soon as a wallet is on any other chain) with the
   local chain id / RPC / vault / keeper strip and a per-token "Mint" using the public
   `MockToken.mint`.

6. **Data separation.** Every invented number moved into one module, `src/demo/` (`constants.ts`,
   `math.ts`, `series.ts`, `data/`). New `DemoBadge` / `LiveBadge` / `DataLegend` components tag the
   UI: the prototype vault table, the demo vault page, Analytics and the wallet dropdown's prototype
   balances all carry a **Demo data** badge; the live surfaces carry **Live on-chain**; both Markets
   and the vault pages carry a one-line legend, and the footer states the split.
   `docs/INTEGRATION.md` maps every prototype data source to a chain read or a demo module.

7. **Config generation.** `npm run sync:shared` reads `../shared/deployment.local.json` +
   `../shared/abis/*.json`, validates every address and the RPC URL, and emits (committed)
   `src/config/generated.ts`. No address or ABI is hand-copied anywhere.

## File map

New:

| Path | What |
|---|---|
| `src/config/generated.ts` | generated addresses + ABIs (do not edit) |
| `src/chain/chains.ts` | chain definitions, deployment chain id, local-chain guard |
| `src/chain/config.ts` | wagmi config (injected connector, per-chain http transports) |
| `src/chain/Providers.tsx` | `WagmiProvider` + react-query provider |
| `src/chain/useConnectWallet.ts` | connect / disconnect / wagmi→store bridge |
| `src/chain/useVault.ts` | `useLiveVault`, `useUserBasket`, `usePreviewDeposit`, `usePreviewRedeem` |
| `src/chain/amounts.ts` | decimal ⇄ bigint, display formatting, bytes32 ascii labels |
| `src/chain/deposit.ts` | minShares, slippage parsing, basket dispatch, approval/balance checks |
| `src/chain/errors.ts` | custom-error decoding to one actionable sentence |
| `src/pages/LiveVault.tsx` | the live page |
| `src/components/live/*` | `LiveDepositCard`, `LiveRedeemCard`, `AdapterList`, `LocalDevPanel`, `LiveVaultTeaser`, `LiveAmountInput`, `TokenAmount`, `StepTrail`, `Message` |
| `src/components/ui/DataBadge.tsx` | `DemoBadge` / `LiveBadge` / `DataLegend` |
| `src/demo/**` | moved: `constants.ts`, `math.ts`, `series.ts`, `data/{vaults,chains,protocol,demoUser}.ts` |
| `scripts/sync-shared.ts` | config generation |
| `scripts/e2e-local.ts` | viem end-to-end against the local chain |
| `src/test/chain.test.ts` | 28 unit tests for the new logic |
| `src/test/render.test.tsx` | render smoke test (jsdom, real providers, real RPC) |
| `docs/INTEGRATION.md` | live vs demo data map |

Modified: `main.tsx` (providers), `App.tsx` (`/live` route), `Layout.tsx` (wallet bridge, footer),
`Header.tsx` (nav entry), `WalletButton.tsx` (real account, network + switch, live balances),
`Welcome.tsx` + `deposit/DepositCard.tsx` (real connect), `store/useStore.ts` (`address`,
`demoWallet`, `setWallet`, rehydration rule), `pages/Markets.tsx` / `VaultDetail.tsx` /
`Analytics.tsx` (live teaser + demo tagging), `vite.config.ts` (include `.test.tsx`), `README.md`,
plus mechanical import updates for the `src/demo/` move.

## Command output

### `npm run sync:shared`

```
> tsx scripts/sync-shared.ts

sync:shared → /Users/Hermes/poolmigo/frontend/src/config/generated.ts
  chainId 46630 · vault 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9 · rpc http://127.0.0.1:8547
  abis: vault(108) mockToken(19) adapter(7) mockAdapter(16)
```

### `npm run build`

```
✓ 6007 modules transformed.
dist/index.html                        0.92 kB │ gzip:   0.47 kB
dist/assets/index-D_27wauX.css        28.40 kB │ gzip:   6.09 kB
dist/assets/ccip-CV-a-dcY.js           4.72 kB │ gzip:   2.02 kB
dist/assets/secp256k1-DbJUvVn7.js     27.83 kB │ gzip:  10.82 kB
dist/assets/index-DnUHcW4t.js      1,119.16 kB │ gzip: 328.97 kB

(!) Some chunks are larger than 500 kB after minification.
✓ built in 3.10s
```

(The >500 kB warning is the wagmi/viem bundle; no code-splitting was added — see Limitations.)

### `npm test`

```
 RUN  v3.2.7 /Users/Hermes/poolmigo/frontend

 ✓ src/test/chain.test.ts (28 tests) 4ms
 ✓ src/test/math.test.ts (19 tests) 8ms
 ✓ src/test/render.test.tsx (3 tests) 136ms
 ✓ src/test/store.test.ts (7 tests) 5631ms

 Test Files  4 passed (4)
      Tests  57 passed (57)
   Duration  5.81s
```

All 26 pre-existing tests still pass unchanged (19 math + 7 store).

### `npm run e2e:local` — against the running Anvil node

```
Poolmigo frontend e2e — local Anvil
rpc http://127.0.0.1:8547 · chain 46630 · vault 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
account #2 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  ✓ signer is Anvil account #2
  ✓ chain id matches shared/deployment.local.json — 46630

── 1. read the vault ─────────────────────────────────────────────
  Poolmigo LP (pmLP), 18 decimals · fee 10% · paused false
  ✓ vault has basket tokens — 2 tokens
  ✓ deposits are not paused
  token 0: mUSDG (6 dp) 0x5FbDB2315678afecb367f032d93F642f64180aa3 · total 115,647.022604
  token 1: mWETH (18 dp) 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 · total 12.435702
  pmLP supply 0.000000106935 (106935060042 base units)
  adapter 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9 · uniswap-v3 · mUSDG/mWETH 0.05% · position 54,462.617295 mUSDG + 5.945955 mWETH
  adapter 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707 · uniswap-v4 · mUSDG/mWETH 0.30% · position 22,862.1397 mUSDG + 2.323987 mWETH
  ✓ adapters are registered — 2

── 2. mint mock tokens to account #2 ─────────────────────────────
  ✓ minted 50,000 mUSDG — balance 392,497.977396
  ✓ minted 50,000 mWETH — balance 150,049.193297

── 3. previewDeposit (offers are maximums) ───────────────────────
  offering 10,000 mUSDG + 10 mWETH
  preview: 0.00000000924667 pmLP (9246676449 base units)
  required: 9,999.999999 mUSDG + 1.075315 mWETH
  ✓ previewDeposit returns a positive share count
  ✓ required ≤ offered for every token (excess is never pulled)
  ✓ at least one token is pulled below the offer — the binding ratio, not the offer, sets the pull

── 4. approve the vault ──────────────────────────────────────────
  ✓ mUSDG allowance covers the required pull — 10,000
  ✓ mWETH allowance covers the required pull — 10

── 5. deposit ────────────────────────────────────────────────────
  ✓ minShares is non-zero (the contract rejects 0) — 0.00000000920044
  ✓ simulated deposit mints exactly the previewed shares — 0.00000000924667
  ✓ Deposited event shares == previewDeposit — 0.00000000924667
  ✓ pmLP balance grew by exactly the minted shares
  ✓ Deposited event amounts == previewDeposit requiredAmounts
  ✓ mUSDG wallet balance fell by exactly the required amount — 9,999.999999
  ✓ mWETH wallet balance fell by exactly the required amount — 1.075315
  ✓ vault total mUSDG grew by the pulled amount — 125,647.022603
  ✓ vault total mWETH grew by the pulled amount — 13.511018
  ✓ pmLP supply grew by the minted shares

── 6. previewRedeem + redeem half ────────────────────────────────
  redeeming 0.00000000809086 pmLP
  previewRedeem: 8,746.954065 mUSDG + 0.940575 mWETH
  ✓ previewRedeem returns a non-empty basket
  ✓ Redeemed event amounts == previewRedeem
  ✓ mUSDG arrived in the wallet in kind — 8,746.954065
  ✓ vault total mUSDG fell by exactly what was delivered — 116,900.068538
  ✓ mWETH arrived in the wallet in kind — 0.940575
  ✓ vault total mWETH fell by exactly what was delivered — 12.570443
  ✓ pmLP balance fell by the redeemed shares — 0.00000000809086
  ✓ pmLP supply fell by the redeemed shares — 0.00000010809
  ✓ half the position is still held after redeeming half

── done ──────────────────────────────────────────────────────────
31 assertions passed.
```

The script is re-runnable; it mints fresh tokens each run, so numbers grow between runs (the totals
above already include earlier runs). It refuses to run against anything that is not a local RPC on
the expected chain id.

### Dev server

`npm run dev` → `VITE v6.4.3 ready in 76 ms`, `http://localhost:5173/` returns HTTP 200.

## Decisions made

- **`/live` is a separate page, not a rewrite of the demo vault page.** The deployed vault is a
  mUSDG/mWETH basket with no APR, price range, NAV or rewards; forcing it into the prototype's vault
  template would have meant inventing exactly the numbers the brief says to isolate. Instead Markets
  gets a live teaser card at the top, the header gets a "Live vault" entry, the demo vault page links
  across, and each side is badged.
- **Reads always target the deployment chain.** Browsing the live vault with no wallet — or with a
  wallet on another network — shows real data; only writes require the right network (with a
  one-click switch).
- **A real connection also opens the demo surfaces.** `useWalletBridge()` mirrors the wagmi account
  into the zustand store so one click lights up both the live vault and the prototype's personal
  areas. The real connection is not persisted (wagmi restores it); only the demo wallet flag is, so a
  reload cannot fake a connected wallet.
- **Approve the offered max, not the required amount.** Required is derived from a preview that can
  move before the transaction lands; approving the user's declared maximum keeps the deposit from
  failing on a stale allowance without ever exceeding what they offered.
- **Strict amount parsing.** More fraction digits than the token has is an error, not a silent
  truncation. Display truncates (never rounds up), so a shown balance is always spendable.
- **Adaptive precision for migoLP.** The bootstrap deposit sets `shares = amounts_[0]`, and the first
  basket token has 6 decimals, so the entire migoLP supply lives around `1e-7` of an 18-decimal token.
  A fixed 4-decimal format renders every share balance as `<0.0001`; `formatAmountSignificant` keeps
  6 significant digits however small the amount is. Worth flagging to the contracts side (see below).
- **ERC-20 `symbol()` / `decimals()` are read for display.** The vault deliberately never reads them
  (`CLAUDE.md`); the frontend must, to render amounts at all. Documented in `INTEGRATION.md`.
- **Polling over block-watching.** Anvil only mines on demand, so a 5 s `refetchInterval` plus an
  explicit refetch after each transaction receipt is the honest cadence.
- **`tsx` added as a devDependency** to run the two TypeScript scripts; `jsdom` +
  `@testing-library/react` for the render smoke test. No component library was added.
- **wagmi v2 (2.19.5), not v3.** wagmi 3 requires TypeScript ≥ 5.9.3 and this project pins
  `typescript ~5.8.3`; bumping the compiler was out of scope for this task.

## Limitations

- The **render smoke test's third assertion is conditional**: if the local chain is down it asserts
  the offline state instead of live data (and warns). It passed against the live chain in the run
  above. It also needs a jsdom shim that strips viem's `AbortSignal` from `Request`/`fetch` — a
  cross-realm quirk of jsdom, not an app bug; the code is commented as such.
- **No browser-level E2E** (no Playwright/Puppeteer in this environment). The transaction paths are
  covered by `scripts/e2e-local.ts` with viem against the real chain, and the React read path by the
  render test; the wallet-signing path (MetaMask popups) was not automated.
- **Bundle is 1.12 MB (329 kB gzip)**, dominated by wagmi/viem. No manual chunking or lazy-loading of
  the chain layer was added — worth doing before any public deployment.
- **RHC mainnet (4663) is a stub.** No deployment exists there; selecting it shows the "cannot reach
  the vault" state. `sync:shared` only knows about `deployment.local.json`.
- The live page has **no transaction history / event feed** and no keeper surfaces (`deployTo`,
  `rebalance`, `emergencyUnwind`) — out of scope for a depositor UI; those belong to the keeper
  service.
- `src/store/useStore.ts` remains outside `src/demo/`: it is the app's state container (theme,
  toasts, wallet bridge) as well as the demo user state. Every invented *figure* it uses comes from
  `src/demo/`.

## Requested upstream changes

None are required for this work to run. Two observations for the contracts/shared owners:

1. **migoLP share scale.** Because bootstrap sets `shares = amounts_[0]` and the first basket token is
   6-decimal mUSDG, the migoLP supply sits at ~`1.07e-7` tokens while the basket holds ~115 k mUSDG.
   Every UI, wallet and explorer will render holder balances as `0.0000001`, and MetaMask's token
   list will show `0`. Nothing is wrong on-chain, but a bootstrap that scales `amounts_[0]` to the
   share decimals (or a demo script that bootstraps with the 18-decimal token first) would make every
   downstream display sane. Frontend-side this is handled, but the wallet's own token display is not
   something the app controls.
2. **`shared/deployment.local.json` has no `adapters` array or ABI version marker.** The frontend
   reads the adapter list from the vault, so this is not blocking; a version/commit field would let
   `sync:shared` warn when the committed `generated.ts` is stale against a redeployed stack.
