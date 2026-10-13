# TASK — Fee-at-exit: skim the performance fee on EVERY path accrued fees leave a position

## Goal
Extend the in-kind performance-fee skim from "harvest only" to EVERY route by which accrued
position fees leave a position, per the owner ruling of 2026-10-03. **No exceptions**
(`emergencyUnwind` included — the old exemption is revoked).

## Owner ruling (LOCKED — build exactly this)
「只要 accrued fee 從 position 出去就要先扣 10% 進到 treasury」 — whenever accrued fees leave a
position, `performanceFeeBps` (currently 1000 bps = 10%; hard cap `MAX_PERFORMANCE_FEE_BPS` = 3000)
is deducted to `treasury` FIRST, in kind, per token. Principal and idle are never skimmed.

## Frozen decisions (build exactly these; deviations → report, do not redesign)
1. **Interface**: `IPositionAdapter.withdrawProportional` and `.unwindAll` gain a THIRD return value
   `uint256[] fees` — index-aligned with `tokens`; `fees[i]` = the accrued-fee value included in
   `amounts[i]`; **must satisfy fees[i] <= amounts[i]**; floor-conservative (never over-report).
   `harvest()` unchanged (its amounts ARE fees). `removeLiquidity` unchanged (already returns the split).
2. **Fee policy lives in the VAULT ONLY** (adapters only report). New private helper:
   `_skimPerformanceFee(address[] memory tokens_, uint256[] memory amounts_) private returns (uint256[] memory cut)`
   — `cut[i] = floor(amounts_[i] * performanceFeeBps / BPS_DENOMINATOR)`; `safeTransfer(treasury, cut[i])`
   for non-zero cuts; `emit PerformanceFeeAccrued(treasury, tokens_, cut)` once if any cut != 0.
   `rebalance()` is refactored onto this helper — its numbers, event and return stay UNCHANGED.
3. **redeem**: adapter slices are delivered INTO the vault (`_withdrawFrom(adapter, sharesWad, address(this))`);
   accumulate `fees` via the registry-aligned `_accumulate`. After the adapter loop: skim on the
   accumulated fees; then transfer `idleOut[i] + amounts[i] - cut[i]` to `receiver` (skip zeros).
   `Redeemed.amounts` AND the redeem return value = what the receiver actually received (net).
   Keep: effects-before-interactions (burn before external calls), `nonReentrant`, NO `position()`/
   oracle reads, no swaps; the skim adds only plain ERC20 transfers — a redemption must never become
   blockable.
4. **pullFrom**: destination stays `address(this)`; skim on the returned fees; the remainder stays as
   vault idle. `PulledFrom` still reports the GROSS amounts the adapter delivered (the cut is visible
   via `PerformanceFeeAccrued`).
5. **removeLiquidity**: skim on the adapter-returned `fees0/fees1` (they land in the vault).
   `LiquidityRemoved` unchanged (still reports the adapter's gross split).
6. **emergencyUnwind**: `unwindAll` returns the new fees vector; accumulate + skim; `EmergencyUnwound`
   and the pause behavior unchanged.
7. **Rounding cascade**: adapter slice floors → cut floors (dust favors holders). `feeBps == 0` or a
   zero slice → no transfer, no event for that token.
8. **Code NatSpec**: update every comment that states "the vault's perf fee only ever applies to
   {harvest}" / "no perf fee — the vault pauses on emergencyUnwind" / the pullFrom "custody move"
   framing → the new rule. The "redeem reads NO adapter reports" property stays TRUE (no `position()`
   reads; the fee split comes from the withdrawal call's own return value) — keep the wording accurate.
9. **Invariants that MUST hold** (assert in tests):
   - `fees[i] <= amounts[i]` on every returned vector;
   - the vault never transfers more than it holds; redeem/pull conservation is exact
     (in == out + cut, per token); `idleOut` snapshot stays pre-interaction;
   - principal floors, v4 banked-fees-never-principal, v3 tokensOwed-only-fees untouched;
   - approval-residue handling and pause semantics unchanged.
10. **Sizes** (EIP-170 = 24,576 B): baseline runtime sizes + margins — vault 23,833 B (743), v3 adapter
    23,331 B (1,245), v4 adapter 23,685 B (891). Keep every `src` contract under EIP-170 WITH margin.
    Refactor to fit (share code through the helper; NEVER weaken or drop a check). If it cannot fit
    after honest refactoring → STOP and list byte options in the report. Only legal trim target:
    test-only fixtures; report any such trim.

## Verified facts (authoritative pointers; if a line drifted, the CODE wins)
- `IPositionAdapter`: `contracts/src/interfaces/IPositionAdapter.sol:31-42` (current 2-value returns).
- Vault `PoolmigoVaultUpgradeable.sol`: storage `treasury` :99, `performanceFeeBps` :100;
  `redeem` :283-346; `pullFrom` :394-408; `removeLiquidity` :444-467 (adapter already returns
  `(principal0, principal1, fees0, fees1, idle0, idle1)`); `rebalance` skim :519-554 (**the reference
  skim**: floor cut + safeTransfer + `PerformanceFeeAccrued`); `emergencyUnwind` :682-705;
  `_withdrawFrom` private helper :1010-1016 (the ONLY call path to `withdrawProportional`; extend its
  pass-through); `_accumulate` :1240+; event `PerformanceFeeAccrued(address indexed treasury,
  address[] tokens, uint256[] fees)` in `IPoolmigoVault.sol:63` — REUSE it; no new events needed.
- v3 adapter `UniswapV3Adapter.sol`: `withdrawProportional` :381-421; `_withdrawFromPosition` :863-881 —
  the fee slice is EXACTLY `take_i - principal_i`, with
  `take_i = principal_i + (tokensOwed_i - principal_i).mulDiv(sharesWad, WAD)` (floor); the `_collect`
  caps ARE `take_i`. `unwindAll` :440-472 — decrease-all releases principal, `_collect(id, this, max, max)`,
  then full balances to `to`; fee part = collected − released principal (same split math as
  `removeLiquidity` :549-559, whose NatSpec already says "adapters report the split, fee policy is the
  vault's").
- v4 adapter `UniswapV4Adapter.sol`: `withdrawProportional` :425-466 — bank slice =
  `bankedFees_i.mulDiv(sharesWad, WAD)` computed BEFORE `bankedFees_i -= <that>` (:445-446) — return
  exactly those pre-decrement values; `amounts` = balance slice ≥ bank slice. `unwindAll` :482-505 —
  zeroes the bank (:491-492), closing remove "takes its fees too" (:496): fees = pre-zero bank + the
  closing-remove's fee part; amounts = full balances sent to `to`.
- Test-side implementers to update (grep-verified): `test/mocks/MockPositionAdapter.sol:127,160`,
  `test/mocks/BrokenPositionAdapter.sol:63,83`, `test/ZapIn.t.sol:69,77`, `test/ZapOut.t.sol:57,77`,
  `test/research/SpotReadSandwich.t.sol:132,159`. `contracts/legacy/**` is NOT compiled — ignore it.
- Extend `MockPositionAdapter` so tests can CONFIGURE the reported fee split (e.g. a settable
  fee-per-withdraw/slice); keep default fee = 0 so unrelated tests are unaffected.
- Suite split (from CI): non-fork = `forge test --no-match-path 'test/fork/*' -vv`; fork =
  `forge test --match-path 'test/fork/*' -vv` (public RHC RPC, rate-limited; v3 ~5 min, v4 ~6.5 min;
  v4 has a known market-flake (48-51/52) — if red, re-run with `RHC_FORK_BLOCK` pinned per
  `contracts/AGENTS.md` and report both readings).
- `foundry.toml`: solc 0.8.34, `optimizer_runs = 100`, fmt `line_length = 120`; RHC alias `rhc`.
  macOS has NO `timeout` binary — do not use it.

## Write scope
- ONLY: `contracts/src/**` and `contracts/test/**`.
- DO NOT TOUCH: `contracts/legacy/**`, `contracts/audit/**`, `contracts/research/**`,
  `contracts/script/**`, `notes/**`, `docs/**`, `.github/**`, `frontend/**`, `backend/**`, `shared/**`,
  any `AGENTS.md` / `CLAUDE.md`, this TASK file. The upgrade-example fixture only if a compile error
  forces it (minimal, test-only, report it).
- Do NOT run any deploy scripts, fork-demo scripts, or git commands (the orchestrator handles commits).
  Do not touch a running anvil on :8547 or the frontend dev server.

## Test requirements
- NEW unit tests (vault): skim on redeem / pullFrom / removeLiquidity / emergencyUnwind;
  `feeBps == 0` → no-op; zero-slice → no-op; floor behavior; `PerformanceFeeAccrued` emitted with the
  right arrays; `Redeemed.amounts` = net; conservation (vault + receiver + treasury deltas reconcile
  per token); redeem still succeeds when a skim transfer is involved (unblockable).
- Adapter tests: `withdrawProportional` / `unwindAll` fee returns == the exact internal split
  (v3: `take − principal` / `collected − principal`; v4: bank decrement / pre-zero bank + closing part);
  `fees <= amounts`.
- Existing tests: where an assertion encodes the OLD fee-free semantics (redeem / pullFrom /
  removeLiquidity / unwind amounts), UPDATE it to the new locked semantics and LIST every changed
  assertion with a one-line justification in the report. Never delete a test; never weaken an
  unrelated assertion; if an expectation conflicts for a reason you cannot justify from this brief,
  STOP and report instead of editing it.

## Acceptance (run ALL; paste raw output lines as evidence)
From `contracts/`:
1. `forge fmt` (touched files), then `forge fmt --check` must pass.
2. `forge clean && forge build` → "Compiler run successful".
3. `forge build --sizes` → report runtime sizes + margins for vault / v3 / v4 vs the baseline table.
4. Warm the npx cache serially (see `.github/workflows/ci.yml` lines 37-45):
   `spec=$(sed -n 's/.*UPGRADES_CORE = "\(.*\)".*/\1/p' lib/openzeppelin-foundry-upgrades/src/internal/Versions.sol)`
   `npx --yes "@openzeppelin/upgrades-core@$spec" >/dev/null`
   then `forge build && forge test --no-match-path 'test/fork/*' -vv` → FULL green (report summary counts).
5. `forge test --match-path 'test/fork/*' -vv` → green (report per-suite counts; flake handling above).
6. `slither . --config-file slither.config.json` → report detector titles + counts vs the
   `contracts/audit/slither-current.txt` baseline (no new High/Medium titles; if any appear, report
   them — do NOT start unrelated fixes).

All long commands MUST run FOREGROUND with the Bash tool timeout raised to 600000 ms. Never
background a suite; never end the turn with a run still pending; never report output you have not
seen. `-p` runs are one-shot: whatever is unfinished when you stop is unfinished.

## Report format (strict order)
1. **DEVIATIONS** — every judgement call, every file touched beyond the list above, every
   brief-vs-code discrepancy (code wins), any step stopped, every UPDATED existing-test assertion
   (one line each).
2. **What changed** — per file, one line each.
3. **Commands + numbers** — raw pasted summary lines for acceptance steps 1-6 (sizes table, suite
   counts, slither titles/counts).
4. **Open items** — anything left, or "none".

No placeholders, no "pending". If a command cannot run, say so and why.
