# TASK: UniswapV4Adapter (Phase B) — Poolmigo vault · basket model

> STATUS: **DRAFT v2 — 2026-09-23**. Supersedes the USD-era version of this brief. The old design
> (`asset()` = USDG, `positionValueUsd()`, TWAP-based NAV) is ARCHIVED at
> `contracts/legacy/adapters/UniswapV4Adapter.sol` and must NOT be resurrected. Basket model is locked
> (`contracts/TASK_REFACTOR.md`); PRD v1.7 keeps the core oracle-free (`notes/PRD-v1.7.md`).
> **2026-09-29: APPROVED TO IMPLEMENT** — the v3 adapter is being built first (see
> `contracts/TASK_V3_ADAPTER.md`); the guarded swap path IS in scope for this pass too.
> Swap-path decision (owner, 2026-09-29): **default (a)** — the guarded in-adapter swap this brief
> specifies; (b) (a standalone SwapAdapter) is RESERVED, not built in this pass, and needs no core or
> interface changes later — see `notes/SWAP-DESIGN.md`.

You are extending the compiling Foundry project in `contracts/` (repo root `/Users/Hermes/poolmigo`).
Read `AGENTS.md` (repo root + `contracts/AGENTS.md`) + `notes/RHC_ADDRESSES.md` FIRST — verified addresses and conventions live there
(never invent an address; every address below comes from that file).

## Goal
Implement `src/adapters/UniswapV4Adapter.sol` — a production-shaped adapter running a REAL Uniswap v4
concentrated-liquidity position for the vault on Robinhood Chain, implementing the CURRENT
`src/interfaces/IPositionAdapter.sol` EXACTLY (no interface changes; no USD).

## The vault's asset model (critical — in-kind basket, no USD anywhere)
- The vault speaks **token vectors** only. NO `asset()`, NO `positionValueUsd()`, NO NAV. Never add a
  USD/price scalar to the adapter's return values.
- `position()` → `(tokens[], amounts[])`: EVERYTHING the adapter controls, INCLUDING uncollected
  fees; parallel arrays, token order STABLE across calls.
- `deploy(amounts)` → pull `amounts[i]` of `position()`-token[i] from the vault (vault force-approves
  first), then place liquidity. Idle tokens not yet in the position are fine — keep reporting them.
- `withdrawProportional(sharesBps, to)` → `floor(sharesBps/10_000)` of everything held, in kind, to
  `to`. NEVER swap on this path.
- `harvest()` → collect fees ONLY (principal untouched), send in kind to the vault.
- `unwindAll(to)` → emergency; everything, in kind.
- Decimals: WETH (18dp) / USDG (6dp) — the adapter does its own decimals math; the vault never reads
  `symbol()`/`decimals()` of basket tokens.

## v4 mechanics you must get right (verify against the deployed contracts with `cast`)
- LP ops go through the v4 **PositionManager** `0x58daec3116aae6D93017bAAea7749052E8a04fA7`
  (verified: `poolManager()` == the PoolManager below): `modifyLiquidities(bytes actions, uint256 deadline)`
  driven by the v4-periphery action encoding (MINT_POSITION, DECREASE_LIQUIDITY, SETTLE_PAIR,
  TAKE_PAIR, BURN_POSITION, ...). **Write minimal interfaces yourself — do NOT vendor Uniswap v4
  source** (v4-core is BUSL-1.1 until 2027-06-15; v4-periphery's license is ambiguous, MIT/GPL-2.0).
  Calling the deployed contracts is fine, and reusing the already-vendored GPL-2.0 v3 math
  (`src/adapters/uniswap/TickMath.sol`, `LiquidityAmounts.sol`) is fine. VERIFY every selector against
  the deployed contracts with `cast`.
- Token flows use **Permit2** `0x000000000022D473030F116dDEE9F6B43aC78BA3`: the adapter approves
  Permit2, then `Permit2.approve(token, PositionManager, amount, expiry)` before settle actions pull
  funds. The position is an ERC721 owned by the adapter (`PositionManager.balanceOf(adapter) == 1`
  after mint).
- Fee collection: `DECREASE_LIQUIDITY` with `liquidity = 0` + `TAKE_PAIR` — fees only, exactly like
  the (archived) v3 design so redemptions can't bypass the perf fee.
- **v4 PoolManager**: `0x8366a39cc670b4001a1121b8f6a443a643e40951`.
- **Target pool** (verified initialized, has liquidity): USDG/WETH `fee = 500`, `tickSpacing = 10`,
  `hooks = 0x0` (currency order + poolId: `notes/RHC_ADDRESSES.md`; secondary pool fee=3000/ts=60 is
  listed there too).

## Swaps — IN SCOPE for this pass, with hard guards
The core vault has NO swap action; the adapter adjusts the ratio itself inside `deploy()` (v4
PoolManager has no external TWAP, so the reference and execution venues are the v3 ones below).
- The v4 PoolManager does NOT expose `observe()`/TWAP externally. Reference the DEEP v3 USDG/WETH
  fee-100 pool TWAP `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` (observation-based, configurable
  window, ≥ 300s floor); execution venue = verified v3 `SwapRouter02`
  `0xcaf681a66d020601342297493863e78c959e5cb2` (deepest liquidity on this chain — document the
  execution-venue choice). NEVER raw spot; too-short history → typed revert, no spot fallback.
- `maxSlippageBps` owner-settable, revert on breach; never an unbounded swap.
- Swaps are token↔token between the basket assets; no stablecoin default, no third asset.
- Swap output lands in the adapter (or directly into the position flow); recipient of router calls
  must never be an arbitrary caller-supplied address.
- Fork-test BOTH: (i) a single-token `deploy()` that internally swaps to reach the range ratio, and
  (ii) a `maxSlippageBps` breach → typed revert.

## Testing — model REAL market making & swaps (REQUIRED)
Fork tests must simulate real market activity, not merely call adapter methods:
- Drive price and fee accrual with REAL swaps: `deal` a funded trading account (or `vm.startPrank` a
  whale) and trade on the fork via the verified v3 `SwapRouter02` (the execution venue). The v4
  position's fees must accrue from real volume in the fee-500 pool, and the pool price must genuinely
  move.
- Cover at least one full cycle: in-kind deposit → `deployTo` (in range) → market moves (several
  swaps; push the price toward and through a range edge) → `rebalance()`/`harvest()` with fees > 0 →
  the guarded internal swap adjusts the ratio (assert the minOut / TWAP bound against a recomputed
  TWAP from the deep v3 pool) → optionally re-range (owner updates the range config) → move again.
- Failure paths under real conditions: a `maxSlippageBps` breach → typed revert; a swap larger than
  needed must be impossible (bounds).
- Fork state is LIVE (the RHC RPC is non-archive): do NOT pin old blocks; assert with explicit
  relative tolerances (bps of deployed) and document each tolerance's rationale.

## Constraints
- Solidity 0.8.34. Custom errors, named returns, CEI ordering, SafeERC20, `onlyVault` on all mutating ops.
- `dex()` = `keccak256("UNISWAP_V4")`; `poolId()` = the real v4 poolId `bytes32`.
- `tickSpacing = 10` must be respected (align ticks); range config settable with bounds (quant owns
  strategy — do not hardcode a rebalance strategy).
- Vendored interfaces live under `src/adapters/uniswap/` (the v3 adapter work adds the v3 set there;
  you add the v4 set under `src/adapters/uniswap/v4/`). `legacy/adapters/` is reference-only — do not
  import from it.
- Do NOT touch the local demo stack: anvil on `:8547` (chain 46630) is in use by the frontend demo.
  Fork tests use the RHC RPC, never anvil.

## Acceptance (verify before declaring done)
1. `forge build` — zero errors.
2. `test/fork/UniswapV4Adapter.fork.t.sol` mirroring the v3 suite, against the REAL fee-500 pool:
   - skip-if-unreachable guard (`vm.skip`) on fork failure;
   - deploy vault (`Upgrades.deployUUPSProxy`) + adapter, wire keeper;
   - deposit both basket tokens (in kind) → keeper `deployTo` → assert
     `PositionManager.balanceOf(adapter) == 1` and `position()` reports plausible in-kind amounts — NO
     USD / NAV assertions anywhere;
   - the two swap cases from the Swaps section above (happy path + slippage breach);
   - accrue fees (swap through the pool, or advance + harvest) → `harvest() > 0` → perf fee in kind
     lands in the treasury;
   - `withdrawProportional` → tokens back within a small tolerance; `onlyVault` guard test.
3. `forge clean` IMMEDIATELY before runs using the OZ upgrades plugin (stale build-info pitfall), then
   re-run the v3 fork suite + full unit suite to prove nothing broke.
   NOTE: the public RHC RPC is rate-limited and each test re-forks (the v3 suite takes ~8 min). That is
   normal — do not "fix" it by changing fork behavior; split by `--match-test` if a run times out.
4. No fabricated output. Report real results including failures.

## Open points (resolve before or during design — do not silently guess)
- PRD §8 #1 (v3-vs-v4 position-management path) — RESOLVED 2026-09-29: both adapters go ahead; this
  brief is the v4 one. §8 #12 (range orders on v4: plain position vs hook) — this brief uses the PLAIN
  pool (`hooks = 0x0`).
- Fee tier, range params, swap-guard specifics — quant + engineering.
- Keeper pull path: `pullFrom(adapter, bps)` is LIVE in the core (destination hard-wired to the vault);
  the adapter must support proportional draining (`withdrawProportional`).
- Audit scope (`contracts/audit/`).

## Do NOT
- Do not modify the vault, the v3 adapter, `IPositionAdapter`, or existing tests.
- Do not resurrect USD: no `asset()`, no `positionValueUsd()`, no NAV/TWAP valuation, no swap-to-stable
  on the withdraw/harvest paths.
- Do not weaken the skip-guard (it must skip, not fail, when the RPC is unreachable).
- Do not resurrect the USD-era fork suite at `legacy/fork-tests/UniswapV4Adapter.fork.t.sol`
  (reference only — it imports the old `TideVaultUpgradeable`); write a fresh basket-model suite.
- Do not price anything from raw spot; no fabricated output.
