# TASK: P1b leftovers — `rangeConstraints()` view + unsatisfiable-width-box hardening

## Goal

Close the two actionable items from the P1b report's open questions, on BOTH adapters in lockstep
(v3 / v4 semantics stay identical), plus the interface — this is the ABI-freeze increment before P3.

## 1. `rangeConstraints()` view (ABI addition, freeze it now)

- `function rangeConstraints() external view returns (int24 minTick, int24 maxTick, int24 minRangeTicks, int24 maxRangeTicks);`
- Declare on `src/interfaces/ILiquidityAdapter.sol` (natspec: one-call read of the owner's box for
  keepers/planners) and implement on `UniswapV3Adapter`, `UniswapV4Adapter` (return the four existing
  storage values). **Keep the four individual getters** — addition only, no removals, no renames.
- `test/mocks/MockLiquidityAdapter.sol` implements `ILiquidityAdapter` — add the view there too or the
  build breaks (mock stays trivial: expose whatever it already stores for constraints, or constant
  defaults if it stores none — mirror its existing constraint fields).

## 2. Unsatisfiable-width-box hardening (both adapters' `_setRangeConstraints`)

- Currently a box where `minRangeTicks_ > maxTick_ - minTick_` is ACCEPTED although NO range can ever
  satisfy it (every `addLiquidity` then reverts until the owner fixes the config).
- Harden: reject it with the EXISTING error `...__InvalidConstraints` (extend its natspec; do not add a
  new error — ABI stability).
- Exactness note (put the one-liner in the code comment): bounds are spacing-aligned, so the box width
  `maxTick - minTick` is a multiple of the spacing and the simple rule `minRangeTicks_ > maxTick_ - minTick_`
  is precisely the unsatisfiability condition — no ceil/spacing math needed.
- Boundary: `minRangeTicks_ == maxTick_ - minTick_` stays ACCEPTED (the full-box range exists).
- `maxRangeTicks_` larger than the box width is fine (a range still exists) — do not touch that rule.
- Both adapters, identical logic and identical revert condition (v3's `_setRangeConstraints` and v4's).

## 3. Tests

- Revert case: `setRangeConstraints` with `minRangeTicks_ = boxWidth + 1` → `__InvalidConstraints`
  (exact args). Boundary case: `minRangeTicks_ == boxWidth` → accepted, getters + `rangeConstraints()`
  reflect it.
- `rangeConstraints()`: assert tuple == the four getters, for defaults at construction AND after a
  set, on v3 and v4 (unit where a venue mock exists, fork otherwise — v3 constraints are covered by
  the fork suite's `test_RangeConstraints_*`; extend it there and the v4 fork equivalent).
- Existing validation cases must stay green unchanged (the 9 invalid shapes; nothing previously
  accepted except the newly-rejected unsatisfiable case changes behavior).
- `test/LiquidityOps.t.sol` (unit, MockLiquidityAdapter): it exercises the vault wrappers against the
  mock — only touch it if the mock's new view needs wiring there.

## 4. Budget + suites

- Sizes must stay in budget: v3 margin 1,820 B / v4 margin 732 B (report `forge build --sizes` before
  and after; this change should cost ~100–200 B per adapter — if it does not fit, refactor, never
  weaken). Vault/executor/zaps untouched → their sizes must NOT move.
- Adapter ABI/behavior changed → re-run ALL FOUR fork suites, not just the touched one:
  v3 (35), v4 (41), zap ×2 (2+2) — the integration proof. Non-fork suite too (187).
- The v4 3% residual case (`test_DeployBalancedMintsRealV4Position`) is the KNOWN live-basis flake:
  provenance-check it (pin the fork block, same-block baseline wei-identical), never loosen the bound.

## 5. Out of scope (deliberate)

- v4 single-unlock remove: DECLINED for now — folding the two unlocks into one `modifyLiquidities`
  batch loses the fee-vs-principal split (one balance measurement = total only), which is exactly what
  the principal floors and the "banked fees never become principal" invariant rely on. Gas is not
  worth weakening that check. (Recorded as an owner-visible decision; revisit only with an explicit
  ruling.)
- Floor-revert shapes (v3 NFPM string vs v4 typed error): informational; keep as-is, keepers treat
  both as a floor breach.
- No vault, executor, zap, script, FE/BE/`shared/`/`notes/` changes. Do not commit. Do not touch
  `AGENTS.md`.

## Deliverable

`REPORT-EXECPLAN-P1B2.md`: deviations first, then exact commands, size table, test counts per suite.
