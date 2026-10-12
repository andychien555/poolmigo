# TASK: Universal Router (official RHC deployment) as the swap execution layer (v3 + v4 venues)

> Owner decision 2026-10-01: the poolmigo LP adapters switch their swap path from direct
> SwapRouter02 calls to **Universal Router** (one integration that covers v3 AND v4 swaps).
> The standalone SwapAdapter (design option (b) in `notes/SWAP-DESIGN.md`) stays RESERVED for
> future routes/venues — do NOT build it here. Redeployment is free: pre-production, nothing
> is deployed on the real chain; no migration paths needed, just new adapter versions.
>
> NOTE: a first agent run (2026-10-01) halted after discovering that the router address from the
> original recon (`0x66a9893c…`) is a mainnet-wired dead copy — see below. This revision carries
> the official, verified addresses. Read this whole section before touching anything.

## Verified live on RHC (2026-10-01, by the maintainer)

- UR **2.1.2 — USE THIS**: `0x204FAca1764B154221e35c0d20aBb3c525710498` — 24,380-byte runtime
  (matches Uniswap's recorded size); embeds RHC's own PoolManager (x11), v3 Factory, WETH9, POSM,
  NFPM, Permit2; `SPOKE_POOL()` resolves to `0xD29C85F1…7978`. Source of truth: Uniswap
  `universal-router` repo, `deploy-addresses/robinhood.json` (added 2026-09; Uniswap verified each
  address onchain before recording).
- UR 2.1.1 (fallback only if 2.1.2 proves unusable): `0x8876789976decbfcbbbe364623c63652db8c0904`
  — 24,546-byte runtime, same correct wiring.
- **DO NOT USE `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`** — a 19,499-byte copy byte-identical
  to Ethereum mainnet, i.e. wired to MAINNET immutables (its PoolManager / v3 Factory / WETH9 have
  no code on RHC). Verified by `--trace` 2026-10-01: every swap fails at the first pool call.
  Uniswap's own fix notes on the same failure mode: "A router deployed against [the wrong]
  PoolManager … cannot execute any v4 command." It is NOT in the official robinhood.json listing.
- Permit2 (canonical): `0x000000000022D473030F116dDEE9F6B43aC78BA3`.
- v3 USDG/WETH fee-100 pool (still the deepest venue for this pair): `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
  (L ≈ 4.58e18, 11.85M USDG + 3,732 WETH).
- v4 USDG/WETH fee-500 / tick-spacing-10 pool (hookless): poolId `0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593`
  (L ≈ 5.84e16 — grew ~5x in a week; the venue-switch target for tests).
- Other infra: POSM `0x58daec3116aae6D93017bAAea7749052E8a04fA7`, NFPM `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`,
  v4 PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, v3 Factory `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`.

## Scope (files)

1. NEW `src/adapters/uniswap/IUniversalRouter.sol` — minimal interface: `execute(bytes commands, bytes[] inputs, uint256 deadline) payable`.
2. `src/adapters/UniswapV3Adapter.sol` — swap path becomes UR `V3_SWAP_EXACT_IN` (single-hop, the adapter's own pool). `Config.swapRouter` now = UR 2.1.2. Guards/flow otherwise unchanged.
3. `src/adapters/UniswapV4Adapter.sol` — swap path becomes UR. Add an owner-settable **venue switch**:
   trade on `refPool` (v3, default — deepest today) OR on its own v4 `poolKey` (for pairs whose deepest venue is v4). v4 venue uses UR `V4_SWAP` actions (exact-in single + settle + take). `refPool` stays THE TWAP reference and the mint-price check in both modes.
4. `src/adapters/uniswap/ISwapRouter02.sol` — remove IF fully unused after the refactor (grep-clean; report it).
5. `src/adapters/uniswap/v4/IPermit2Minimal.sol` — extend only if required (approve/allowance likely already sufficient).
6. Tests: update existing unit + `test/fork/UniswapV3Adapter.fork.t.sol` / `UniswapV4Adapter.fork.t.sol`; ADD fork cases: (a) v3-venue swap via UR (fill within guard budget), (b) v4-venue swap via UR on the live v4 fee-500 pool (small size), (c) allowance hygiene incl. Permit2 (inner + outer resets to 0). Also add a grep-style guard test/check that `0x66a9893c` (the dead copy) appears NOWHERE in `src/` or `script/`.
7. `script/DemoLocalFork.s.sol` + `script/fork-demo-up.sh` — new constructor args / UR 2.1.2 constant. **Do NOT redeploy the frozen demo stack** (maintainer runs the runbook after review). Keep the all-mock `DemoLocal.s.sol` path buildable/passing.
8. `contracts/REPORT-UR-ROUTER.md` — deliverable report (see bottom).

OFF-LIMITS: `src/PoolmigoVaultUpgradeable.sol`, `src/interfaces/IPositionAdapter.sol`, `src/periphery/PoolmigoCreate3.sol`,
`AGENTS.md` (all levels), `notes/` , `audit/`, `docs/`, `frontend/`, `backend/`, `test/legacy/`, `test/research/`.
No git operations.

## Requirements

1. **Encoding MUST be derived from authoritative sources for the deployed router (UniversalRouter
   2.1.2 — tag `v2.1.2` / `release/2.1.x`)** — Uniswap docs / `universal-router` + `v4-periphery`
   sources matching 2.1.2 — never invented from memory: command bytes (`V3_SWAP_EXACT_IN`, `V4_SWAP`),
   the V3 input layout (recipient, amountIn, amountOutMin, path bytes, payerIsUser), the V4 action
   bytes + params (exact-in single, settle, take; settle mechanism incl. Permit2), and `execute`
   deadline semantics (in-tx usage: pass a `block.timestamp`-style value — verify against the
   source). Cite sources in the report and PROVE the encoding by live-fork execution against the
   official router (the trace must show the RHC pool reached via the RHC factory / PoolManager).
2. **Permit2 approvals**: for each swap set ERC-20 allowance to Permit2 AND the Permit2 inner allowance
   to UR = exactly `amountIn`; reset BOTH to 0 before returning. Invariant stays: no approval survives
   any call. Recipient / TAKE target is ALWAYS the adapter itself.
3. **Guards unchanged**: TWAP from `refPool.observe()` (>= twapWindow, no spot fallback); `minOut` =
   TWAP quote x (1 - maxSlippageBps); exact-input sized at most the surplus held; v4 spot-vs-TWAP
   deviation check stays for mints; UR failure surface (its custom errors, e.g. too-little-received
   equivalents) mapped to the adapters' typed errors; events updated only additively (include venue).
4. **Construction coherence checks re-anchored**: keep the "venues checked at construction" property
   (pool identity via the pool's own methods; UR and Permit2 have code). Do not rely on UR getters
   that do not exist — 2.1.x exposes `SPOKE_POOL()` but no `factory()`.
5. Venue switch is owner-settable (event-emitting) on the v4 adapter, with validation (venue targets
   are the known `refPool` / own `poolKey`; pair identity consistent). Default: v3 venue.
6. Keep custody rules: tokens never leave vault <-> adapter; router/venue recipients never
   caller-supplied.

## Tests & verification

- `forge clean && forge build` before suites. `forge fmt` before finishing.
- Unit: full `forge test` green (all existing suites, updated as needed).
- Fork (live RHC, slow — v3 suite ~5 min, v4 ~6.5 min): both suites green after updates + the new
  UR cases above. No flaky-retry masking of real failures.
- macOS: no `timeout`, `shasum -a 256` (not sha256sum). Use fixture `rhc` alias / public RPC.

## Report (`contracts/REPORT-UR-ROUTER.md`)

What changed per file; the EXACT command/action bytes + input encodings with source citations;
live-fork evidence (tx hashes/sections, fill vs guard budget, trace of the pool reached); test
counts (unit + fork); gas observations (optional, vs SwapRouter02 if cheap); open items/risks
(e.g. hook-bearing v4 pools — default route stays hookless; the dead-copy 0x66a9893c trap worth
recording). English. Done = build green + unit green + both fork suites green + report written.
