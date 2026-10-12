# TASK: P5 — multi-position adapters (one whitelisted pool adapter manages many ranges)

## Status / direction (owner-commissioned, 2026-10-07)

The keeper must manage MULTIPLE ranges inside ONE owner-whitelisted adapter. The owner whitelists the
pool adapter once and sets the range box + a position-count cap; the keeper opens, tops up, trims and
closes individual ranges itself — "Owner 一次授權 pool adapter… keeper 在限制內自行管理區間。新增區間
便不必重新找 owner 註冊 adapter." This matches the frozen trust model (`notes/EXECUTION-PLANS.md`):
keeper composes typed plans across whitelisted adapters, inside the constraint box, single signer.

Today: one adapter = one pool = ONE live position (v3 `tokenId`/`tickLower`/`tickUpper` single slots;
an `addLiquidity` at different bounds reverts `RangeMismatch` — close (burn) first). A second
simultaneous range needs a second adapter = another owner `addAdapter` (capped at `MAX_ADAPTERS` = 32).

Scope: **v3 adapter = full implementation.** The shared `ILiquidityAdapter` changes, so the **v4
adapter + mock conform in P5; full v4 bookkeeping = P5b** (v4 has only ~200 B EIP-170 headroom — its
own size work). The interface in §1 is the settle point; implementation starts after the owner's glance.

## 1. `ILiquidityAdapter` v2 (FROZEN — the interface)

```solidity
struct AddLiquidityParams {          // UNCHANGED shape — bounds live here
    int24 tickLower; int24 tickUpper; uint128 liquidity; uint128 minLiquidity;
    uint256 maxAmount0; uint256 maxAmount1; uint256 minSwapOut;
}
struct RemoveLiquidityParams {       // + positionId (new FIRST field)
    uint256 positionId; uint128 liquidity; uint256 minPrincipal0; uint256 minPrincipal1;
}
function addLiquidity(AddLiquidityParams calldata p) external
    returns (uint256 positionId, uint128 added, uint256 spent0, uint256 spent1,
             uint256 refunded0, uint256 refunded1);
function removeLiquidity(RemoveLiquidityParams calldata p) external
    returns (uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1,
             uint256 idle0, uint256 idle1);
function closePosition(uint256 positionId) external                 // NEW
    returns (uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1);
function positionIds() external view returns (uint256[] memory);    // NEW
function position(uint256 positionId) external view                   // NEW
    returns (int24 tickLower, int24 tickUpper, uint128 liquidity);
function configVersion() external view returns (uint32);            // NEW (pin version, per adapter)
function maxPositions() external view returns (uint16);             // NEW
function setMaxPositions(uint16 n) external;                        // NEW (owner; n <= cap below)
// REMOVED: tokenId(), positionState() (single-slot views — the set views replace them)
// UNCHANGED: rangeConstraints(), position() [aggregate report], and the IPositionAdapter surface
//            (deploy / withdrawProportional / harvest / unwindAll) + swapExactIn
```

Semantics (frozen):

- `addLiquidity` — bounds match a LIVE position exactly → **increase it**; otherwise **mint a new
  position** when `liveCount < maxPositions()`, else revert (typed). Bounds validated per NEW position
  against the SAME owner box + spacing (unchanged gate). `minLiquidity` / pull caps / refund flow
  unchanged. Returns the position id (v3: the NFT tokenId).
- `removeLiquidity` — removes from the named position; `liquidity == 0` idle-refund mode unchanged
  (positionId unused). A full remove keeps the position LIVE at 0 liquidity (today's parity; the v4
  zero-position pitfall note still applies).
- `closePosition(positionId)` — decrease ALL liquidity of that position, collect, **burn the NFT**;
  other positions untouched. Principal/fee split as remove (fee-at-exit unchanged).
- `positionIds()` / `position(id)` / `configVersion()` / `maxPositions()` as above; the aggregate
  `position()` report keeps its shape (sums over live positions; ≤ cap iterations).
- `setMaxPositions` — owner-only (`Ownable2Step`, same owner as `setRangeConstraints`), emits the
  event; `MAX_POSITIONS_PER_ADAPTER = 8` hard constant; deploy-time default 1 (raise deliberately;
  demo stack sets 4).
- Proportional ops keep their signatures: `withdrawProportional(sharesWad)` slices EVERY live position
  (per-position floor) + adapter idle, burning all positions only at `sharesWad == 1e18`; `harvest()`
  collects fees from ALL positions; `unwindAll()` closes all (emergency).
- `deploy()` (legacy vault `deployTo` path): 0 positions → fresh TWAP-range mint (unchanged); exactly
  1 → top-up at its bounds (unchanged); ≥ 2 → revert (ambiguous) — multi-range top-ups go through
  `addLiquidity` per range.

## 2. Vault (`PoolmigoVaultUpgradeable` / `MySunVaultUpgradeable`)

- `removeLiquidity` wrapper: the `LiquidityRemoved` id now comes from `p.positionId` (drop the
  `la.tokenId()` pre-read — also saves bytes).
- NEW keeper wrapper `closePosition(IPositionAdapter adapter, uint256 positionId)`: gates identical to
  `removeLiquidity` (registered / not paused / `CAP_LIQUIDITY`); calls the adapter; skims the
  performance fee on reported fees (fee-at-exit unchanged); emits
  `PositionClosed(adapter, positionId, principal0, principal1, fees0, fees1)`. No approvals, no
  storage change.
- No accounting changes: in-kind vector model unchanged, no per-position ledger; `redeem` / `pullFrom`
  / `emergencyUnwind` keep their shape — the adapter loops internally.

## 3. `PlanExecutor`

- Pin becomes per-POSITION: `{ adapter, positionId, tickLower, tickUpper, liquidity, configVersion }`
  (same fields as today — the single `tokenId` slot becomes per-position `positionId`).
- Coverage rule (replaces "one pin per adapter"): for every adapter named by a component —
  (a) every LIVE position has exactly one pin; (b) every pin matches a live position exactly
  (id ∈ `positionIds()`, bounds + liquidity equal); (c) every pin's `configVersion` equals the
  adapter's current. Zero live positions → zero pins (an add that mints stays covered).
- Kinds: NEW `KIND_CLOSE_POSITION_BY_ID = 5` — payload `abi.encode(uint256 positionId)`, calls
  `vault.closePosition`. `KIND_CLOSE_POSITION` (4, `pullFrom(adapter, 10_000)`) stays = close ALL
  ("整個 adapter"). Remove payload 3 → 4 words; add unchanged (7); swap/harvest unchanged (0).

## 4. Tide worker (`backend/`)

- `src/plan.ts`: pins built from `positionIds()` + `position(id)` + `configVersion()`;
  `closePositionById(adapter, id)` builder; `PAYLOAD_SIZE` map updated; `assertPlanWellFormed`
  enforces the per-adapter bijection client-side; pin fetch sites updated.
- Integration test: a plan that opens a 2nd range, tops up the 1st, closes the 2nd — against the
  local stack (real `executePlan`).
- Range-selection POLICY (which ranges to open / retire and their weights) = follow-up phase (P6),
  not here. Same for wiring the tick to send plans (unchanged status).

## 5. Acceptance

- **Step 0 (before code): size probe** — marginal bytecode cost of the multi-position bookkeeping on
  v3 (`23,884 B` / 692 B margin today), same method as the P1c probe (stub the additive paths, measure
  via `forge build --sizes`). If the projection busts EIP-170, report a split plan BEFORE proceeding;
  never weaken checks to fit.
- Unit: multi-position lifecycle (mint 2 ranges; same-bounds increase; cap revert; remove-by-id
  isolation; close-by-id isolation + burn; proportional / harvest / unwind across N; empty-position
  parity; constraints per new position; events; wrapper gates; pin bijection failure modes: missing /
  extra / stale / version). Mock adapter conforms to v2.
- Fork: v3 suite green (reads migrated to `positionIds()[0]` etc.) + cheap multi-range cases;
  `RHC_FORK_BLOCK` honored. Vault semantics change → re-run the fork suites.
- Sizes recorded before/after for v3 adapter + vault (vault margin 363 B — the new wrapper must fit).
- Backend: `pnpm test` green incl. the multi-position plan e2e; `script/export-abis.sh` → regenerate
  the 9 artifacts + FE/BE `sync-abis` (FE has no logic use of the changed views).
- Rollout: local stack redeploy (fork-demo freeze norm) with the demo adapter `maxPositions = 4`;
  4663 rehearsal update = owner txs, coordinate before touching; public snapshot untouched.
- Docs: `notes/EXECUTION-PLANS.md` §P5 (append), `contracts/AGENTS.md` surface + size lines,
  `REPORT-EXECPLAN-P5.md` on completion.

## 6. Non-goals

- No standalone per-position fee-collect op (harvest covers all; remove/close collect) — trivially
  addable later if wanted.
- No changes to `MAX_ADAPTERS` / `MAX_TOKENS`, roles, fee policy, or the accounting model.
- No v4 full bookkeeping (P5b), no cross-version upgrade compatibility work (local redeploy is the
  norm until mainnet state).

## 7. Owner review points (defaults chosen; veto before the run)

1. `MAX_POSITIONS_PER_ADAPTER = 8`; `setMaxPositions` default 1 (demo sets 4).
2. `deploy()` reverts at ≥ 2 live positions (no multi-range top-up guessing).
3. Close-by-id = new plan kind 5, separate from close-all (kind 4).
4. v4 = interface conformance only in P5.
