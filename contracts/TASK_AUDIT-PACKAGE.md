# TASK: audit package — `contracts/audit/` pre-audit deliverable

> Orchestrator brief, 2026-09-30. Executed by one agent; the orchestrator verifies and commits.
> Context: Phase B landed (real `UniswapV3Adapter` + `UniswapV4Adapter`, live-fork tested); the local
> demo runs them on a frozen RHC fork; the next step is a **professional audit**. This task assembles
> the pre-audit package a firm receives: scope, architecture, invariants, threat model, self-reported
> issues, test/tooling evidence — professional English, precise, no marketing, no fabrication.

**Pin: commit `3bf6e1a841778be8097b603798086077434f29ad` (2026-09-30).** Everything describes this
commit. (`contracts/src` and `contracts/test` are unchanged since `396fbe5`, so the CI run
36625150756, unit 71/71 and the slither gate stated below are valid for this exact code.)

## Deliverables (NEW files; do not modify anything else)

`contracts/audit/`:
1. **`README.md`** — package index + handover: "NOT audited / pre-audit package" banner; pin + date;
   repo layout; how to build & test (short); what is where (the docs below + prior materials:
   `SECURITY_REVIEW.md` — NOTE it predates the in-kind refactor AND the adapters: say so, its
   false-positive triage stays useful where the code still matches; `slither-report.txt`/
   `aderyn-report.md` refactor-era raw reports; the fresh current-code scan produced here); engagement
   process = "as agreed with the engagement lead" (do not invent a process).
2. **`01-scope.md`** — scope tiers: **A** vault core + interfaces / **B** A + both adapters
   (**recommended**) / **C** B + periphery (CREATE3). In-scope table for every `contracts/src/**/*.sol`
   file: path, LOC, `shasum -a 256`, one-line description, SPDX note (`src/adapters/uniswap/` v3-vendored
   set is GPL-2.0-or-later; everything else MIT — per-file SPDX is the truth). Out of scope: tests,
   mocks, scripts, legacy, research, and ALL of frontend/backend (policy layer, not protocol code).
   Dependencies (read `contracts/lib/*` versions) + compiler settings (from `foundry.toml`).
3. **`02-architecture.md`** — system overview; actors (owner / keeper / depositor / adapters — derive
   the exact powers from the code); in-kind vector accounting (deposit formula, redeem, VS=VA=1 rationale,
   performance fee on harvested fees only); flows: genesis, deposit, redeem, `deployTo`, `pullFrom`
   (destination hard-wired), `rebalance` (harvest + deploy), `emergencyUnwind`, add/remove adapter,
   upgrade (UUPS, ERC-7201 namespaces, the V2 upgrade script); adapter mechanics: v3 (pool, TWAP
   guard trio, `maxSlippageBps`, SwapRouter02 swap inside `deploy()`, `feeGrowthInside` fee accounting,
   zero-swap withdraw path) and v4 (PoolManager/POSM, `extsload` reader, fee banking rationale,
   reference venue = the deep v3 pool); periphery CREATE3 note; security posture (no oracle, no USD,
   zero-swap core, keeper cannot move funds out).
4. **`03-invariants.md`** — **≥ 15 numbered invariants**, each: statement · where enforced (file /
   function) · how tested (unit test file + test name; fork suite where applicable) · status. Mine the
   actual tests under `contracts/test/` for names — do not invent. Cover at least: accounting
   conservation & rounding directions (floor shares / ceil required), `totalTokens()` = idle + Σ
   adapters, redeem pro-rata + fee slice to the redeemer, fee only on fees, core never swaps / never
   reads a price except adapter `position()` at deposit math, registry-gated adapters & tokens, keeper
   ops only between vault and registered adapters, owner-only admin, pause stops keeper money movement
   (check exact semantics), supply cap incl. genesis, upgrade auth, reentrancy guards.
5. **`04-threat-model.md`** — trust assumptions; attack surfaces with mitigation + residual risk +
   pointer to evidence. Sources: `contracts/research/spot-read/findings.md` (+`report.txt`),
   `notes/SWAP-DESIGN.md`, `contracts/TASK_V3_ADAPTER.md` / `TASK_V4_ADAPTER.md` guard sections,
   `SECURITY_REVIEW.md` triage, `REPORT-V3/V4` open points. Include at least: donation / first-depositor
   (virtual offsets + mandatory minShares); spot-read manipulation at deposit (worst case = over-priced
   depositor, bounded); TWAP staleness/manipulation for adapter deploys (window, guards, minOut,
   slippage bound — fail-closed); cross-venue basis (v4 prices/rebalances against the v3 TWAP; fee-500
   v4 pool is thin — reads are cheap to move; accepted, `minShares` bound); sandwich on adapter swaps
   (bounded by minOut/TWAP ±); adapter-loop failure mode (a reverting adapter blocks `totalTokens()` /
   redemptions — owner-curated registry, standing audit topic); rounding/precision; ERC-20 quirks
   (`forceApprove`); reentrancy; upgrade/admin risk (owner = intended multisig + timelock on mainnet);
   keeper griefing bounds; the missing rescue/sweep (stray non-registry tokens).
6. **`05-known-issues.md`** — self-reported items + open questions, each: id, description, impact,
   status (**by design / mitigated / open — auditor opinion welcome**), evidence. Include at least:
   - K-1 `previewRedeem` NatSpec overclaims "exact amounts" for concentrated-liquidity adapters;
     measured WETH shortfall 0–479 wei / USDG 0–1 base unit (see `REPORT-FORK-DEMO.md` §2.2);
   - K-2 virtual offsets VS = VA = 1 (size rationale at the constants);
   - K-3 owner-gated genesis K (manual one-time valuation);
   - K-4 no rescue/sweep for non-registry tokens (design question: pre- or post-audit);
   - K-5 keeper service (backend/) sends only `deployTo`/`rebalance`; `pullFrom` exists and is manual;
   - K-6 v4 has no built-in oracle; reference = v3 TWAP; basis bounded by `maxSlippageBps` (fail-closed);
   - K-7 uint128/uint160 casts (SafeCast hardening, from SECURITY_REVIEW H-4) — verify the sites.
   - Verify each against the code before writing; fix wording; add anything else you actually find.
7. **`06-tests-tooling.md`** — build & test commands; captured results: unit 71/71 (re-run now,
   capture the real tail), fork v3 18/18 & v4 19/19 (cite the captured runs in `REPORT-V3-ADAPTER.md` /
   `REPORT-V4-ADAPTER.md` / `REPORT-FORK-DEMO.md` + exact commands; do NOT re-run — 5–6.5 min each on a
   rate-limited public RPC); demo stacks (mock + frozen fork, briefly); CI (`ci.yml`: build+unit,
   slither gate `fail_on: high`, aderyn) + the private nightly fork workflow (`fork-tests.yml`); how an
   auditor runs the fork suites.
8. **Fresh static analysis on the current code** (slither + aderyn are already installed at
   `~/.local/bin` — do NOT install anything new): mirror the CI invocation from
   `.github/workflows/ci.yml` (read it), run over the current contracts, save
   `slither-current.txt` + `aderyn-current.md`, and summarize counts + triage of any High finding in
   `05-known-issues.md`. If the environment refuses (solc selection, foundry integration), record the
   exact error, fall back to the CI evidence, and say so — never fake output.
9. **`make-bundle.sh`** — builds the handover tarball from the pinned commit via `git archive`
   (COMMIT arg, default HEAD): include `contracts/` except `out/`, `cache/`, `broadcast/` (keep `lib/` —
   deps are vendored, the bundle must be self-contained), `notes/PRD-v1.7.md`,
   `notes/PRD-ORACLE-FREE-ADJUSTMENTS.md`, `notes/SWAP-DESIGN.md`, `notes/RHC_ADDRESSES.md`,
   `notes/NAMING.md`, root `README.md` (+ `LICENSE` if it exists — verify). Output path arg with a sane
   default (`$HOME/poolmigo-audit-<shortsha>.tar.gz`); print size + a listing summary; verify the
   tarball excludes `out/cache/broadcast` and includes `lib/`. Run it once and keep the artifact.
10. **`contracts/REPORT-AUDIT-PACKAGE.md`** — build report: §1 what was produced, §2 decisions /
    flagged points, §3 test & tooling table, §4 REAL captured outputs (unit run tail, static-analysis
    summaries, bundle listing + size, a few sha256 lines). Fill §4 with actually captured text BEFORE
    finishing.

## Rules

- Read the code; every factual claim must be traceable to a file/line or captured output. No invented
  numbers, no invented test names, no marketing language.
- Do NOT touch `contracts/src`, `contracts/test`, `AGENTS.md`, or anything outside `contracts/audit/`
  + the one REPORT file. No git operations (the orchestrator reviews, verifies, commits).
- Long commands in the FOREGROUND with the Bash timeout raised; never end with a run pending.
- English for all package docs (they go to the auditor); precise professional tone; tables fine.
- Keep `contracts/audit/` tidy: numbered docs + raw static-analysis files; no stray temp files.
