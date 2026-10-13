# TASK: Strategy layer P1b — V4 mirror of the precise-liquidity capability

## Goal

Make `UniswapV4Adapter` implement the SAME `ILiquidityAdapter` capability that P1 landed on the v3
adapter, with identical external semantics, so the existing keeper-gated vault wrappers
(`addLiquidity` / `removeLiquidity`) work against either adapter **without vault changes**.

Reference implementation to mirror: `src/adapters/UniswapV3Adapter.sol` (P1, commit `3a8a279`) plus the
interface `src/interfaces/ILiquidityAdapter.sol`. Design rationale: `../notes/EXECUTION-PLANS.md`
(sections "Precise liquidity", "Range constraints", "Three-way accounting"). P1c (`c3cda5c`) already
extracted the swap machinery — the v4 adapter is at 20,844 B runtime with a 3,732 B margin before you
add anything.

## Required external surface (mirror exactly)

1. `setRangeConstraints(int24 minTick, int24 maxTick, uint24 minRangeTicks, uint24 maxRangeTicks)`
   — owner-only; default = fully open; validation semantics and revert conditions identical to the v3
   adapter (inverted/equal bounds, box narrower than minRangeTicks, etc.). Bounds must be tick-spacing
   aligned for the adapter's PoolKey; reject unaligned input the same way v3 does.
2. `rangeConstraints() view` — same tuple shape.
3. `addLiquidity(AddParams)` — absolute tick bounds inside the constraint box, EXACT raw-liquidity
   target, acceptable-liquidity floor, pull caps per token, `minSwapOut`; ratio swap through the shared
   `UniversalRouterSwapExecutor` (reuse the adapter's existing quote/venue logic); pull only what is
   needed from the vault, refund the unused delta; never touch pre-existing idle; different bounds than
   the existing position → revert ("close first" rule).
4. `removeLiquidity(RemoveParams)` — exact raw liquidity; caller principal floors enforced; idle-refund
   mode when `liquidity == 0` (return idle, do not touch the position); report principal vs fees vs
   idle SEPARATELY in the event.
5. `tokenId() view` (position NFT id) — the vault uses it to label `LiquidityRemoved`.

Use `ILiquidityAdapter` unchanged. If a small shared helper/library removes duplication between the two
adapters, that is allowed as long as v3 behavior is untouched and v3's size does not regress.

## V4-specific semantics that MUST be handled explicitly

- **Raw liquidity is native here.** v4's `PositionManager.modifyLiquidity` takes a `liquidityDelta`
  directly — do not re-invent the v3 amounts-polling path. But the required token amounts must be
  computed from the **v4 pool's own current sqrtPriceX96** (the PoolManager computes the settle deltas
  from its own pool state); sizing off the v3 ref pool price would mis-size the pull.
- **v4 gives no `amount0Min`/`amount1Min`.** The caller's principal floors must be enforced by the
  ADAPTER: use the `BalanceDelta` returned by `modifyLiquidity` and revert if the settled amounts are
  worse than the caller's floors (mirror v3's floor semantics, including that floors apply to the
  principal removed, not the fee slice). Name the error consistently with v3's floor error.
- **Banked fees never become principal.** v4 settles fees on every liquidity modification. The
  principal/fee split reported by `removeLiquidity` must keep the existing invariant intact, and
  `removeLiquidity` must not silently convert banked fees into principal (add a test asserting exactly
  this).
- **Settlement path unchanged in kind.** Keep using the adapter's existing Permit2
  (`SETTLE_PAIR` / `TAKE_PAIR`) plumbing and the existing `_approvePermit2` / `_revokePermit2` zeroing
  discipline; the executor call for the ratio swap is the only out-of-contract call you add.
- **Venue switch is for PRICING/quotes only.** Do not change `_checkRouter`/venue validation, TWAP
  guard, dust-skip, or the `V3_REF_POOL` behavior; the new liquidity ops must run on the adapter's own
  v4 pool.

## Budget discipline (this is the risky part)

v4 adapter budget: 20,844 B now, hard cap 24,576 B → **3,732 B of margin**. Target ≤ 24,000 B runtime.
If your first implementation does not fit: apply the same class of semantics-preserving refactors P1/P1c
used (shared private helpers, tighter revert paths, packed params) and/or omit the
`previewAddLiquidity`-equivalent view on v4. NEVER weaken a check to save bytes. Report the final size
table.

## Tests

- Fork suite `test/fork/UniswapV4Adapter.fork.t.sol` is the primary proof (real RHC v4 POSM + PoolManager
  + the real executor). Add cases mirroring the v3 P1 fork cases where they apply: constraints
  set/revert (including spacing alignment), add at absolute bounds inside the box, add rejected outside
  the box, exact raw-liquidity target, floor enforcement via the BalanceDelta path, idle-refund mode,
  principal/fee/idle split, "different bounds → revert", and the Permit2/executor allowance trail
  assertions (adapter grants the router nothing, executor layers zeroed, nothing at rest).
- Unit level: extend only where a v4 venue mock genuinely exists or can be added cheaply in
  `test/mocks/` — do not fake the POSM into something that proves nothing. A real re-entrant/edge unit
  test is worth more than ten mock-shaped ones.
- Keep EVERY suite green: 187 unit, fork v3 35, fork v4 25 (now +N), zap 2+2.
- KNOWN FLAKE, do NOT "fix" it: `test_DeployBalancedMintsRealV4Position` ("WETH residual < 3%") is
  driven by the live v3-TWAP/v4-spot basis at the fork block. If it trips, pin the fork block, show the
  baseline (`cadf209`) fails wei-identically at that same block, and report it as provenance — never
  loosen the bound.

## Out of scope

- Vault, zaps, FE, BE, `shared/`, `notes/` — untouched.
- No new deployment components (the executor already exists).
- Do not commit; leave changes in the working tree. Do not touch `AGENTS.md`.

## Deliverable

`REPORT-EXECPLAN-P1B.md`: deviations first (and why), then exact commands, size table before/after
(`forge build --sizes` for the v4 adapter and the executor), test counts per suite, gas deltas for the
new add/remove paths, and any open design question the strategy side must settle.
