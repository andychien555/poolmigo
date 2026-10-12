# TASK — Fee-at-exit, phase 2: report NET (position() fee component)

Phase 1 (fee-at-exit本体) is in HEAD: adapters report the fee split on every exit path and the vault skims
`performanceFeeBps` (10%) to treasury in kind (see `contracts/TASK_FEE-AT-EXIT.md`; vault helpers `_exitAll` /
`_skimPerformanceFee`). Phase 2 (owner ruling 2026-10-03) closes the loop on READS: since any accrued position fee
that leaves a position is skimmed FIRST, a `position()` reporting fees GROSS overstates what holders can actually
extract — deposit pricing and the frontend are fed by `totalTokens()` → `position()`. Make the two REAL adapters
report the NET (post-skim) fee component.

## The rule (exact)

For each token, the adapter's reported fee component becomes:

    feesNet = fees − floor(fees * performanceFeeBps / 10_000)

with `performanceFeeBps` read LIVE from the vault on every call. Subtraction form, NOT
`fees * (10_000 − bps) / 10_000` (they differ by up to 1 wei; the subtraction matches the vault's actual `cut`
1:1). Principal and idle components are NOT touched. `bps == 0` ⇒ gross (unchanged); `bps == 10_000` ⇒ fee
component 0.

## Where (composition is already exact — net only the fee terms)

- `UniswapV3Adapter.position()` (`contracts/src/adapters/UniswapV3Adapter.sol`): the fee component is
  `p.tokensOwed0/1 + _pendingFees(...)` computed inside `_positionAmounts`. Keep the structure; e.g.
  `uint256 fees0 = p.tokensOwed0 + fee0; amounts[0] = balance + principal0 + fees0 - fees0.mulDiv(bps, 10_000)`.
  (Placement inside `_positionAmounts` vs `position()` is your call — one place, no duplication.)
- `UniswapV4Adapter.position()` (`contracts/src/adapters/UniswapV4Adapter.sol`): the fee parts are (a) the BANK
  (`bankedFees0/1` counters — part of the adapter's token balance, per the "idle (incl. banked fees)" doc) and
  (b) the feeGrowth accrual inside `_positionAmounts`. Net the SUM of that token's fee parts with ONE cut
  (`fees = banked + accrual; feesNet = fees − floor(fees*bps/10_000)`), subtracted from the reported amount.
  Comment the chosen arithmetic so the ≤1 wei equivalence to the exit paths is explicit.
- Read bps via `IPoolmigoVault(vaultAddress).performanceFeeBps()` — the existing vault immutable/reference,
  live per call (no caching). Import the interface if not already imported; if `performanceFeeBps()` is not
  declared on it, add it (additive, view only). If a non-fork test constructs a real adapter against a vault
  double that lacks the getter, extend the double — never a try/catch fallback.

## NatSpec / docs

- `position()` NatSpec in BOTH adapters: the fee part is NET of the vault's perf fee (fee-at-exit rule) — i.e.
  what would actually be extractable; principal/idle stay gross holdings. Keep it short.
- `IPositionAdapter.position()` doc: "everything this adapter holds" → the extractable value: idle + principal
  + fees net of the vault's performance fee.
- `PoolmigoVaultUpgradeable.totalTokens()` / `previewRedeem` NatSpec: if they characterize adapter reports as
  gross, sync to net. Search "gross" near those functions.
- Search `docs/` (and any contracts README) for `position()` / `totalTokens()` wording and sync; keep edits
  minimal, one line on the fee-at-exit rule where the split is described.

## Tests (must stay at full strength)

- The FORK suites exercise the REAL adapters — expect many expectation updates in
  `contracts/test/fork/UniswapV3Adapter.fork.t.sol` and `contracts/test/fork/UniswapV4Adapter.fork.t.sol`:
  every expected value derived from `position()` (helpers `_held`/`held`/`left`/previews/`totalTokens` and
  zap-fork expectations) must be recomputed for the net fee part. The gross fees are available in the same
  tests via `_accruedFees()` and the bank counters — keep equality assertions EXACT
  (e.g. `expectedGross = heldNet + cut` with `cut = grossFees.mulDiv(PERF_FEE_BPS, BPS)`).
  Do NOT weaken `assertEq` to `assertLe`/approx unless impossible; justify any relaxation in the report.
- Add to EACH of the two fork files one focused test: `position()`'s fee component == grossFees −
  floor(grossFees×bps/10_000) with fees actually accruing; gross when bps==0 (set, check, restore); fee
  component 0 when bps==10_000.
- Unit suites use mocks — DO NOT change `MockPositionAdapter` / `MockLiquidityAdapter` or the vault; the mocks
  are vault-accounting doubles, not the production reporting policy. Unit tests must keep passing unchanged
  (fix a test's assumption if one genuinely breaks, not the mock).
- Zap fork suites consume `previewRedeem`/`position()` indirectly — update if red. `test/research` stub: only
  if it fails to compile.

## Hard constraints

- Do NOT touch: withdraw/exit paths, `_skimPerformanceFee`, events, storage layout, `deploy`/`swap` logic.
  This is a REPORTING change only (view code + docs + tests).
- ABI frozen: `position()` selector/shape unchanged; no new external functions beyond any additive interface
  declaration above.
- EIP-170 margins are thin (last measure: v3 ≈ 905 B, v4 ≈ 529 B): keep added code minimal (one small helper
  or inline reads); if sizes blow, inline rather than adding machinery.

## Verification to run (report exact results)

1. `forge fmt`
2. `forge clean && forge build`, then `forge build --sizes` — record both adapter margins.
3. Unit: `forge test --no-match-path 'test/fork/*'` — must stay green (239 at phase-1 HEAD).
4. Fork: `forge clean && forge build` then
   `forge test --match-path 'test/fork/*' --rpc-url https://rpc.mainnet.chain.robinhood.com
   --fork-retries 30 --fork-retry-backoff 2000` (v3 + v4 + zaps; the retry flags REQUIRE the
   explicit --rpc-url; a small budget — 8 x 800 ms — is NOT enough for the ~10-min market tests,
   which throttle out retryably around 11 min). RHC
   public RPC is non-archive and drops storage fetches mid-test (deep price walks → `FatalExternalError`) — the
   retry flags ride over it; always use them. A failure whose log shows `FatalExternalError` or
   `failed to get storage` is INFRA, not a code bug: rerun it, don't chase it.
5. `slither . --config-file slither.config.json` — no new findings vs the phase-1 baseline.
6. Report: files changed, per-suite test counts, any assertion relaxed (with reason), new v3/v4 sizes.
