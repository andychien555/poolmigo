# TASK: refresh the pre-audit package (`contracts/audit/`) for the UniversalRouter migration

> Maintainer note: the existing package was built from commit `9090396` (bundle
> `~/poolmigo-audit-9090396.tar.gz`). Since then the swap layer moved to the official UniversalRouter
> 2.1.2 (commit `26c049c` + `c4007f0`; report `contracts/REPORT-UR-ROUTER.md`; decision record
> `notes/SWAP-DESIGN.md` §"Router decision — executed"). The package MUST be brought back in line
> before it can be handed to any auditor. You update DOCS + static-analysis artifacts only; the
> maintainer commits, then builds the bundle (`git archive` of the committed tree).

## Scope: files you touch

UPDATE (content):
1. `audit/README.md` — pinned commit `242218a…` (the code-under-review commit); the package commit
   will be its successor with `contracts/src` and `contracts/test` byte-identical (state this the way
   the previous edition stated its `396fbe5` relationship; the bundle manifest carries the real
   archive commit). Update: package date, "Code under review: `contracts/src/**` (N files; hashes in
   `01-scope.md`)" — recount; contents table (supporting docs: ADD `contracts/TASK_UR-ROUTER.md` +
   `contracts/REPORT-UR-ROUTER.md`; note the previous bundle edition `poolmigo-audit-9090396.tar.gz`
   is superseded); the public-snapshot parity paragraph — the public snapshot now TRAILS the pin (it
   predates the UR migration); keep the previous parity proof as historical, state the snapshot will
   be refreshed at the next publish. Keep the NOT-AUDITED banner.
2. `audit/01-scope.md` — per-file table recomputed for the new commit: LOC, nSLOC, SHA-256, SPDX
   (same method as this edition used — reproduce it; if the method is not stated, note the tool used).
   `adapters/uniswap/IUniversalRouter.sol` is NEW (MIT; written from the public 2.1.2 ABI — NOT
   vendored source; contains the command/encoding codec and the strict factory probe — it is IN
   scope). `adapters/uniswap/ISwapRouter02.sol` LEFT `src/` (moved to `test/fork/utils/` so the fork
   suites' market takers keep an independent v3 venue — test-only, out of scope; say so). Fix every
   stale statement about the swap venue/router in the scope notes.
3. `audit/02-architecture.md` — swap-layer sections: execution = the adapter's configured
   UniversalRouter 2.1.2 (`0x204FAca1764B154221e35c0d20aBb3c525710498` on RHC; v3 `V3_SWAP_EXACT_IN`
   on the adapter's own pool; v4 `V4_SWAP` = SWAP_EXACT_IN_SINGLE + SETTLE + TAKE); Permit2 two-layer
   approvals exactly `amountIn`, both zeroed in the same call; output re-measured as the adapter's
   balance delta and re-checked `>= minOut`; error mapping (`V3TooLittleReceived` /
   `V4TooLittleReceived` → the adapters' typed `SlippageExceeded`); construction coherence (router
   anchored via `V3_POSITION_MANAGER().factory()` == the pool's factory, strict single-word probe;
   `RouterMismatch` / `NoCode`); v4 adapter **owner-settable venue switch** (`setSwapVenue`,
   default `V3_REF_POOL`, targets constructor-validated; `REF_POOL` remains the TWAP reference in
   BOTH venues; on the v4 venue the swap moves the mint price — min-out bounds it, liquidity sized at
   the post-swap spot). Add `setSwapVenue` to the owner powers list. Grep the file for
   `SwapRouter02` and reconcile every mention (SwapRouter02 remains a live RHC venue — the backend
   fee test's independent trader uses it — but is no longer any adapter's path).
4. `audit/03-invariants.md` — update affected invariants (allowance hygiene now spans BOTH layers:
   ERC-20→Permit2 and Permit2→router, exact amount, expiry = this block, both reset; swap output
   re-checked locally) and ADD an invariant for swap provenance: swaps execute only through the
   constructor-verified router on a constructor-verified venue, venues never caller-supplied, the
   venue switch is owner-only over a validated enum. Keep numbering coherent; cite the enforcing code
   + the fork tests that prove it (names from `REPORT-UR-ROUTER.md` §4).
5. `audit/04-threat-model.md` — add/adjust surfaces with mitigation + residual + evidence:
   rogue/mis-wired router (the RHC dead copy `0x66a9893c…` — construction anchor + unit grep guard +
   runbook `poolManager()` check; note its reported mainnet NFPM HAS code on RHC, hence the strict
   probe), Permit2 approval hygiene, venue-switch abuse (owner-only; min-out still bounds), router
   dependency (indirect anchoring caveat), UR error-surface mapping vs pass-through. Reconcile stale
   swap descriptions.
6. `audit/05-known-issues.md` — continue the K numbering (last = K-17): add K-18 (swap gas +31% via
   UR — informational, keeper-only path), K-19 (v4 venue on a thin pool reverts rather than filling —
   by design; switch only when v4 is deeper), K-20 (router anchoring is indirect — fails safe on
   getter changes). Mirror `REPORT-UR-ROUTER.md` §8 items 2–6 where they belong. Check the existing
   K entries + §S.3 for statements invalidated by the migration; fix only what is wrong (mark
   historical where a statement is intentionally left).
7. `audit/06-tests-tooling.md` — captured results: RUN the unit suite fresh at this commit
   (`forge clean && forge build` then `forge test --no-match-path 'test/fork/*'`; record the exact
   runner line — 73/73, 0 skipped) and record the fork-suite results from `REPORT-UR-ROUTER.md` §3/§6
   (v3 22/22, v4 25/25) PLUS the maintainer's independent re-run (v3 22/22 in 325.6 s; v4 25/25 in
   326.6 s) — append a one-line addendum to `contracts/REPORT-UR-ROUTER.md` §6 recording that re-run
   so the evidence lives in-repo. Update bundle section: `make-bundle.sh` (new yarn will be built by
   the maintainer from the package commit — record its parameters/VERIFY_BUILD step), and note the
   fork-demo bring-up now carries TWO live-fork guards (UR `poolManager()`, SwapRouter02 `factory()`)
   — the second exists to keep the backend fee tests' trader venue cached in the frozen state.
8. REGENERATE fresh over the new code: `audit/slither-current.txt` (slither 0.11.4,
   `slither . --config-file slither.config.json` — CI invocation) and `audit/aderyn-current.md`
   (aderyn 0.6.8). Match the existing files' header format. Diff the new findings against the
   previous runs and triage any new high/medium in `05-known-issues.md` (the CI gate is
   `fail_on = high` — it must still pass; report the gate status).
9. `audit/make-bundle.sh` — add `contracts/src/adapters/uniswap/IUniversalRouter.sol` to the
   required-entries check list (step 5). Nothing else changes.

LEAVE UNCHANGED: `audit/SECURITY_REVIEW.md`, the historical `slither-report.txt` /
`aderyn-report.md` / `slither-refactor.txt` / `aderyn-refactor.md`, `contracts/REPORT-AUDIT-PACKAGE.md`.
OFF-LIMITS: everything outside `contracts/audit/` + the one addendum line in
`contracts/REPORT-UR-ROUTER.md` (no `src/`, `test/`, `script/`, `notes/`, frontend/backend, no git
operations, no bundle build).

## Verification you must do

- `forge clean && forge build` then the unit suite (record the exact line). `forge fmt --check` clean.
- Read the actual adapter code before writing claims (the UR report is a source, not the truth).
- Every "how tested" reference must name a real test that exists at this commit.
- Recount scope files with `find contracts/src -name '*.sol'` and make README/scope numbers agree.
- macOS: `shasum -a 256` (no `sha256sum`), no `timeout`.
- Write `contracts/REPORT-AUDIT-UR.md` (English): per-file change summary, new-file list + hashes
  count, slither/aderyn delta + gate status, unit result line, any residual doubt. Done = docs
  updated + fresh analysis artifacts + unit suite green + report written. The maintainer then
  commits and builds the bundle.
