# TASK: UniswapV3Adapter (Phase B) — Poolmigo vault · basket model

> STATUS: **DRAFT v2 — 2026-09-23**. Supersedes the USD-era version of this brief. The old design
> (`asset()` = USDG, `positionValueUsd()`, TWAP-based NAV, swap-to-USDG on every path) is ARCHIVED at
> `contracts/legacy/adapters/UniswapV3Adapter.sol` and must NOT be resurrected. The basket model is
> locked (`contracts/TASK_REFACTOR.md`); PRD v1.7 keeps the core oracle-free (`notes/PRD-v1.7.md`).
> **2026-09-29: APPROVED TO IMPLEMENT** — both Phase B adapters go ahead (v3 first, then v4); the
> guarded swap path IS in scope for this pass.
> Swap-path decision (owner, 2026-09-29): **default (a)** — the guarded in-adapter swap this brief
> specifies; (b) (a standalone SwapAdapter) is RESERVED, not built in this pass, and needs no core or
> interface changes later — see `notes/SWAP-DESIGN.md`.

You are extending the compiling Foundry project in `contracts/` (repo root `/Users/Hermes/poolmigo`).
Read `AGENTS.md` (repo root + `contracts/AGENTS.md`) and `notes/RHC_ADDRESSES.md` FIRST — conventions plus VERIFIED addresses
(never invent an address; every address below comes from that file).

## Goal
Implement `src/adapters/UniswapV3Adapter.sol` — a production-shaped adapter that gives the vault a REAL
Uniswap v3 concentrated-liquidity position, implementing the CURRENT `src/interfaces/IPositionAdapter.sol`
EXACTLY (read it first; do not change it).

## The vault's asset model (critical — in-kind basket, no USD anywhere)
- The vault speaks **token vectors** only. There is NO `asset()`, NO `positionValueUsd()`, NO NAV.
  Never add a USD/price scalar to the adapter's return values.
- `position()` → `(tokens[], amounts[])`: EVERYTHING the adapter controls, INCLUDING uncollected
  fees; parallel arrays, token order STABLE across calls. (Spot read of venue state is the accepted
  design: a manipulated/lagged read can only over-price a depositor — vault `deposit` enforces a
  non-zero `minShares`.)
- `deploy(amounts)` → pull `amounts[i]` of `position()`-token[i] from the vault (the vault
  force-approves first), then place liquidity. Holding some tokens idle (not yet in the position) is
  FINE — `position()` must keep reporting them. Return the tokens/amounts actually deployed.
- `withdrawProportional(sharesBps, to)` → send `floor(sharesBps/10_000)` of everything held, in kind,
  to `to` (decrease liquidity + collect as needed). NEVER swap on this path.
- `harvest()` → collect fees ONLY (principal untouched), send in kind to the vault, return what was sent.
- `unwindAll(to)` → emergency; everything, in kind, to `to`.
- Decimals: pools here are WETH (18dp, token0) / USDG (6dp, token1). The adapter does its own decimals
  math; the vault never reads `symbol()`/`decimals()` of basket tokens.

## Swaps — IN SCOPE for this pass, with hard guards
The core vault has NO swap action. The adapter adjusts the ratio ITSELF, inside `deploy()`: when the
idle tokens passed in don't match the ratio the configured range needs, it swaps the surplus into the
deficit token through the verified v3 `SwapRouter02`, then places liquidity. Rationale: this is the
ONLY way the keeper can adjust the basket ratio (passive + active market making).
- Price reference MUST be manipulation-resistant: venue TWAP via `IUniswapV3Pool.observe()` over a
  configurable window (owner-settable, sane floor e.g. ≥ 300s). NEVER raw `slot0` for sizing;
  too-short history → typed revert, no spot fallback.
- `maxSlippageBps` owner-settable, revert on breach; never an unbounded swap.
- Swaps are token↔token between the basket assets; no stablecoin default, no third asset.
- Swap output lands in the adapter (or directly into the position flow); the keeper/EOAs never touch
  custody; recipient of router calls must never be an arbitrary caller-supplied address.
- Fork-test BOTH: (i) a single-token `deploy()` that internally swaps to reach the range ratio, and
  (ii) a `maxSlippageBps` breach → typed revert.

## Testing — model REAL market making & swaps (REQUIRED)
Fork tests must simulate real market activity, not merely call adapter methods:
- Drive price and fee accrual with REAL swaps through the real pool: `deal` a funded trading account
  (or `vm.startPrank` a whale) and swap USDG↔WETH through the verified `SwapRouter02` on the fork.
  The fees the position earns must come from THAT swap volume, and the tick must genuinely move.
- Cover at least one full cycle: in-kind deposit → `deployTo` (in range) → market moves (several
  swaps; push the price toward and through a range edge) → `rebalance()`/`harvest()` with fees > 0 →
  the guarded internal swap adjusts the ratio (assert the minOut / TWAP bound against a recomputed
  TWAP) → optionally re-range (owner updates the range config) → move again.
- Failure paths under real conditions: a `maxSlippageBps` breach → typed revert; a swap larger than
  needed must be impossible (bounds).
- Fork state is LIVE (the RHC RPC is non-archive): do NOT pin old blocks; assert with explicit
  relative tolerances (bps of deployed) and document each tolerance's rationale.

## Constraints
- Solidity 0.8.34. Use v3 INTERFACES only (`INonfungiblePositionManager`, `IUniswapV3Pool`,
  `ISwapRouter02`, TickMath, LiquidityAmounts); vendor minimal interfaces into
  `src/adapters/uniswap/` — it MUST compile. (Official v3 libs vs hand-vendored minimal ones: your call.)
- `legacy/adapters/uniswap/` already holds minimal `IUniswapV3PoolMinimal`, `ISwapRouter02`, `TickMath`,
  `LiquidityAmounts` (interfaces/libs only — safe to copy/adapt); `INonfungiblePositionManager` is NOT
  there and must be vendored. Do not import from `legacy/` — copy into `src/adapters/uniswap/`.
- Access: constructor stores the vault; `onlyVault` on all mutating ops.
  `dex()` = `keccak256("UNISWAP_V3")`; `poolId()` = `bytes32(uint256(uint160(pool)))`.
- The adapter owns the v3 NFT position (recipient/owner of the tokenId).
- Custom errors, named returns, CEI ordering, SafeERC20.
- Range config: settable with bounds (quant owns strategy — do not hardcode ticks/thresholds).
- Do NOT touch the local demo stack: anvil on `:8547` (chain 46630) is in use by the frontend demo.
  Fork tests use the RHC RPC, never anvil.

## Verified context (Robinhood Chain — from notes/RHC_ADDRESSES.md)
- Target pool: USDG/WETH v3 fee 100 `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` (fee tier is a
  quant/§8 #1 call — keep it configurable).
- Swap venue: v3 `SwapRouter02` `0xcaf681a66d020601342297493863e78c959e5cb2` (deepest liquidity;
  document this execution-venue choice).

## Acceptance (verify before declaring done)
1. `forge build` — zero errors.
2. `test/fork/UniswapV3Adapter.fork.t.sol`:
   - `vm.createSelectFork` on the RHC RPC (alias `rhc` in foundry.toml); SKIP (`vm.skip(true)`) if
     the fork RPC is unreachable.
   - deploy vault (`Upgrades.deployUUPSProxy`) + adapter, wire keeper; deposit both basket tokens
     (proportional, in kind); keeper `deployTo(adapter, amounts)` → assert `NFPM.balanceOf(adapter) == 1`
     and `position()` reports plausible in-kind amounts (vs deployed, with tolerance) — NO USD / NAV
     assertions anywhere.
   - the two swap cases from the Swaps section above (happy path + slippage breach).
   - accrue fees (swap through the pool, or advance + harvest) → `harvest()` > 0 → the perf fee in
     kind lands in the treasury.
   - `withdrawProportional` → user gets tokens back within a small tolerance; `onlyVault` guard test
     (non-vault caller reverts).
3. `forge clean` IMMEDIATELY before any test/deploy run that uses the OZ upgrades plugin (stale
   build-info pitfall — see `contracts/AGENTS.md`); then run the full suite to prove nothing broke.
4. No fabricated output. Report real results including failures.

## Open points (resolve before or during design — do not silently guess)
- PRD §8 #1 (v3-vs-v4 position-management path) — RESOLVED 2026-09-29: implement BOTH adapters;
  this brief is the v3 one.
- Fee tier, range params, swap-guard specifics (TWAP window, max slippage) — quant + engineering.
- Keeper pull path: `pullFrom(adapter, bps)` is LIVE in the core (destination hard-wired to the
  vault); the adapter must support proportional draining (`withdrawProportional`).
- Audit scope (`contracts/audit/`).

## Do NOT
- Do not change `IPositionAdapter`, the vault, or existing tests.
- Do not resurrect USD: no `asset()`, no `positionValueUsd()`, no NAV/TWAP valuation, no swap-to-stable
  on the withdraw/harvest paths.
- Do not hardcode a rebalance strategy (ticks/thresholds are settable params).
- Do not resurrect the USD-era fork suite at `legacy/fork-tests/UniswapV3Adapter.fork.t.sol`
  (reference only — it imports the old `TideVaultUpgradeable`); write a fresh basket-model suite.
- Do not fabricate test output.
