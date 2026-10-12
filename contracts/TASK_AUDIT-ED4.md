# TASK — audit package edition 4 (refresh at the current pin)

You are refreshing the **pre-audit package** in `contracts/audit/` so it describes the CURRENT code.
Read the whole existing package first (README, 01–06, make-bundle.sh header) — it has its own format,
tone and methods; match them exactly. This task is a WRITING + VERIFYING task. Do not change code.

## The pin

- New pin = current repo HEAD: **383f5b1** (record the full sha in the docs).
- `contracts/src` was last touched by `70b0bad` (P3); commits after it are docs/tooling only. Verify:
  `git diff --stat 383f5b1 -- contracts/src` is empty (working tree == pin).
- Edition 3 pinned `579cb60` (2026-09-30). This is **edition 4**; it supersedes ed.3 and its bundle
  `4466dd5`. Package date: 2026-10-02.

## What changed since ed.3 (context — verify everything from source)

- **P1/P1b**: precise liquidity — keeper `addLiquidity` / `removeLiquidity` with exact raw targets and
  absolute bounds inside the owner's range-constraint box (`setRangeConstraints`); v4 mirrors v3
  (principal floors `__PrincipalBelowFloor`, bank-vs-idle split, empty-position `_bankFees` guard).
- **P1b2**: `rangeConstraints()` view + unsatisfiable-box hardening (two exact clauses; report
  `contracts/REPORT-EXECPLAN-P1B2.md`).
- **P1c**: swap machinery extracted into the shared stateless `src/swap/UniversalRouterSwapExecutor.sol`
  (adapters call it; replaces the old in-adapter swap path narrative).
- **P3**: `ISwapAdapter` (capability `swapExactIn`), adapter **capability mask** `CAP_LIQUIDITY` /
  `CAP_SWAP` derived via ERC-165 at `addAdapter` (owner can narrow via `setAdapterCapability`, never
  fake), vault-funded `swapExactIn` (FREE IDLE only) + `SwapSettled` / `AdapterCapabilitySet` events,
  `positionState()` pins incl. `configVersion`, periphery `PlanExecutor` (typed components, per-keeper
  sequential nonces, deadline, `expectedTotalSupply`, pins + coverage check, two keeper sets; emits
  `PlanExecuted(planId, keeper, nonce)`; `planId = keccak256(abi.encode(plan))`).
- **Zaps**: `src/periphery/PoolmigoZapIn.sol` / `PoolmigoZapOut.sol` (periphery tier; guards from the
  sandwich study; local-node mint faucet wording lives in FE — derive the actual on-chain behaviour
  from source, don't assume).
- **P4**: deploy scripts + ABI exports only (app level; audit scope is contracts/src).
- `src/PoolmigoVaultV2.sol` was REPLACED by `src/PoolmigoVaultUpgradeExample.sol` (trimmed test-only
  fixture; `version()` / `setMinRebalanceInterval` were removed to fit EIP-170).
- Current sizes (`forge build --sizes`, re-derive): v3 adapter 23,450 B (margin 1,126), v4 adapter
  24,174 B (402), vault 24,078 B (498), `UniversalRouterSwapExecutor` 4,378 B, `PlanExecutor` 6,195 B,
  upgrade-example fixture 24,519 B (57, test-only). Hard limit 24,576 B.

## Deliverables (edit ONLY under contracts/audit/)

1. **01-scope.md** — recompute the WHOLE table (method note is in the file; keep it, update the pin):
   file list = `git ls-files contracts/src` (**26 files** now — confirm), LOC = `wc -l`, nSLOC from
   fresh aderyn output, SHA-256 = `git show 383f5b1:<path> | shasum -a 256`, SPDX = the file's line.
   Tier table: extend Tier C to the full periphery set (Create3 + zaps + `swap/` executor +
   `planExecutor`) and recompute per-tier nSLOC. Mark Δ vs ed.3 wherever the hash changed. New files
   entering scope; `PoolmigoVaultV2.sol` leaving (replaced by the fixture — keep a one-line note).
2. **02-architecture.md** — add the strategy layer: precise-liquidity ops + constraint box +
   `rangeConstraints()`, the shared swap executor (replaces the old in-adapter swap description),
   capability masks + vault-funded `swapExactIn`, `PlanExecutor` (component kinds, nonces, pins,
   trust), zaps; update the actors-and-powers table; remap every file:line ref to the new pin; refresh
   the upgrade/rollout model (fresh chain = no upgrade step; existing deployments: upgrade vault →
   deploy new adapters → `addAdapter` for mask derivation; CREATE3 path; rehearsal option lives in
   notes/DEPLOY-RHC.md — do NOT import notes content, just don't contradict it).
3. **03-invariants.md** — add strategy-layer invariants, each with enforcement site (file:line) and
   EXACT test names grepped from the current test tree (LiquidityOps.t.sol, StrategyP3.t.sol,
   PlanExecutor.t.sol, SwapExecutor.t.sol, fork suites). Remap/refresh every existing cited test name
   and count (old numbers like "v3 22/22" are stale). Keep the honest test-gap list, extended.
4. **04-threat-model.md** — new surfaces & residual risks: PlanExecutor (keeper trust within
   constraints, nonce replay, payload typing, pins/coverage, two keeper sets), `swapExactIn`
   (free-idle-only funding), capability mask (ERC-165 unchecked probe reads 0, owner narrowing),
   zaps, EIP-170 tightness; refresh trust assumptions ("what is NOT enforced on-chain").
5. **05-known-issues.md** — **APPEND-ONLY**: keep K-1…K-20 text and IDs; add K-21+ for the new
   concrete items (derive ONLY from facts in the repo: e.g. tight bytecode margins, keeper trust model
   as by-design/open, fee-on-settle and v4 banked-fees open questions, K-16/K-11 deployment checks
   still open). Mark resolved-in-code where applicable; never renumber or delete. Refresh the
   static-analysis triage section with the fresh runs.
6. **06-tests-tooling.md** — fresh evidence: run the unit suite yourself
   (`forge clean && forge build && forge test --no-match-path 'test/fork/*'`, expect 223) and record
   the raw counts; fork suites are NOT to be re-run — cite the maintainer runs of 2026-10-02 with
   provenance: v3 42/42 pinned @ block 77,611,048 AND live 42/42; v4 52/52 live; ZapIn 2/2, ZapOut 2/2
   (Robinhood Chain public RPC, Foundry 1.8.3). CI evidence: public snapshot CI run 36946686771 at
   `1c71e90` (3 jobs green: build+non-fork tests, slither, aderyn) — note its provenance (curated
   public snapshot; non-fork tests only). Tool versions: Foundry 1.8.3, slither 0.11.4, aderyn 0.6.8.
7. **README.md** — pin/date → edition 4 (supersedes ed.3 `4466dd5`); new "what changed since ed.3"
   section; fix the tree listing (`PoolmigoVaultV2` → `PoolmigoVaultUpgradeExample`, new files, test
   count 83 → current); update "Public snapshot parity": the snapshot was refreshed 2026-10-02 →
   `crypto-crazer/poolmigo` main = `1c71e90`, 308 files; state the parity method/claim honestly —
   snapshot `contracts/src` equals the pin's (commits after `d5095e1` touched only notes/harness) —
   verify what you can read-only via `gh api` and say exactly what you verified vs asserted. Update
   the maintainer-questions table (security contact still placeholder; deployment still not executed
   on mainnet — the rehearsal option exists but is internal).
8. **slither-current.txt / aderyn-current.md** — OVERWRITE with fresh runs (keep the historical dumps
   untouched). Expected: slither 215 results / 0 High; aderyn clean run at new pin. If results differ,
   record reality — never force the expected number.

## Hands-off

- Do NOT edit: `contracts/src/**`, `contracts/test/**`, `contracts/script/**`, `contracts/foundry.toml`,
  root `.gitattributes`, `contracts/audit/make-bundle.sh`, `SECURITY_REVIEW.md`,
  `slither-report.txt`, `slither-refactor.txt`, `aderyn-report.md` (historical — leave as-is; if one of
  them now badly misleads, you may add a one-line "superseded — see X" pointer at its top ONLY).
- No git commit / push / tag. Leave the working tree with your edits; the orchestrator reviews and commits.
- No new files inside `contracts/audit/` beyond the two `*-current.*` refreshes.
- English. Keep the NOT-AUDITED banner everywhere it exists. Placeholders (`security@poolmigo.example`)
  stay by decision.

## Verification you must do yourself

- Re-read every doc after editing; make ALL numbers agree across README / 01 / 06 / manifest mentions.
- Grep the shipped docs for stale names: `PoolmigoVaultV2`, `IPositionAdapter` (renamed? check),
  "in-adapter swap", "83 tests", `ISwapRouter02`, old line refs.
- Every cited test name must exist: grep each one.
- If a tool run fails or something cannot be verified, say so explicitly in your report — never fabricate.

## Environment

- `export PATH="$HOME/.foundry/bin:$PATH"` at the start of every shell block (forge/cast are there;
  slither/aderyn/node/npx on PATH already).
- OZ-plugin builds: `forge clean && forge build` before validator-touching commands; don't interleave
  builds with the plugin runs.
- Working dir: `~/poolmigo/contracts`.

## Report (final message)

List: files changed; every correction you made to facts stated in THIS brief; everything you could not
verify; the exact commands+results for slither / aderyn / unit suite / sizes; and anything a reviewer
should double-check first.

---

**Addendum (2026-10-02, fix round).** This spec was executed for edition 4 at pin `383f5b1`; the package was then
refreshed again for the fix round at pin `fcf0e65` (exact-delivery pulls / strict participation / K-22 / `optimizer_runs`
100) — see `notes/EXECUTION-PLANS.md` → "Fix round" and the audit `README.md`. Where this brief and the current package
disagree on numbers (test counts, sizes, slither totals, pins), the package is authoritative.

