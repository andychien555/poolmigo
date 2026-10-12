# TASK: refresh the pre-audit package (`contracts/audit/`) — edition 3 (post pre-audit fixes)

> Context: edition 2 pinned `242218a` (bundle `~/poolmigo-audit-01b2362.tar.gz`). Since then the
> maintainer decided to fix six self-reported items BEFORE the audit (K-8, K-9, K-13, K-14, K-16, K-17
> + K-1 wording) — see `contracts/REPORT-PREAUDIT-FIXES.md` and `TASK_PREAUDIT-FIXES.md`. Also: the
> repo license is now BUSL-1.1 (root `LICENSE`, commit `0be2669`; SPDX headers swept across
> `contracts/src|script|test`), `pullFrom` converts bps→wad via the named `WAD_PER_BPS` constant, and
> the audit package's content policy changed: **`notes/`, `contracts/TASK_*.md` and `contracts/research/`
> are WITHHELD from this and future bundles** (internal working documents; excerpts available to the
> auditor on request) — enforced via root `.gitattributes` `export-ignore` (already committed; verify)
> plus `make-bundle.sh` assertions.

Pinned commit (code under review): **579cb60** (`chore: backend ABI sync + export-abis.sh plugin-pitfall
note`). `contracts/src` at this pin is byte-identical to the fixes commit `b53a9ed` (later commits
touched only tooling/generated files). The commit carrying THIS refresh will be its successor; confirm
no source drift before finishing:
`git diff --stat 579cb60 -- contracts/src contracts/test contracts/foundry.toml` (must be empty).

## Scope: files you touch

1. `audit/README.md` — pinned commit + date; scope-file count (recount; expected unchanged at 19, but
   hashes changed); **contents table**: add root `LICENSE` (BUSL-1.1) + `.gitattributes`; REMOVE the
   notes/-subset row; mark `TASK_*.md` / `research/` as withheld ("internal working documents are
   withheld from the package; excerpts available on request"). Remove the previous "no LICENSE"
   warnings. Snapshot-parity paragraph: public snapshot trails (predates UR migration; license added).
   Maintainer-questions section: security-contact placeholder stays by decision ("domain not
   registered yet"); strip-question resolved (withhold policy); fixes resolved (in code, this edition);
   LICENSE resolved.
2. `audit/01-scope.md` — recompute the full table at the pin (same method as edition 2; `shasum -a 256`;
   same LOC/nSLOC tool). SPDX column: most files now `BUSL-1.1` (swept); six vendored files remain
   `GPL-2.0-or-later` (enumerate them). Rewrite references to withheld docs as "internal working
   document (withheld; available on request)". Cross-check count: `find contracts/src -name '*.sol' | wc -l`.
3. `audit/02-architecture.md` — update: adapter withdrawal interface is now
   `withdrawProportional(uint256 sharesWad, address to)` with `sharesWad = floor(fraction·1e18)`
   (redeem: `floor(shares·1e18/S)`; keeper `pullFrom` converts bps exactly via `WAD_PER_BPS = 1e14`);
   `redeem` skips adapters when `sharesWad == 0`; `previewRedeem` documented as upper bound; NEW
   `forceRemoveAdapter` owner recovery path (never calls the adapter, swap-and-pop, assets remain in
   the removed adapter, re-`addAdapter` re-counts); deposit rule is now the K-14 dust rule (held token
   optional iff `shares·T_i < S`); CREATE3 effective salt = `keccak256(salt‖msg.sender)` (cross-chain
   determinism requires the same deployer per chain); `evm_version = cancun` pinned (toolchain).
4. `audit/03-invariants.md` — update affected invariants + evidence refs: redemption-proportionality
   bound is now `< Σ_a H_a,i/1e18 + A + 1` raw units per token (+ ≈ one liquidity unit per CL
   adapter); adapter fraction in `(0, 1e18]`; extend the registry-liveness invariant: any registered
   adapter can be dropped by the owner without calling it (`forceRemoveAdapter`) — the recovery path
   for K-9 (cite the new test). Keep numbering coherent (edition 2 had 26 invariants).
5. `audit/04-threat-model.md` — update affected surfaces: dust donation residual (< 1 wei of the
   omitted token per skipping deposit; griefing needs `s·T_i ≥ S`, a material holding); broken-adapter
   block → force-remove recovery (owner-trusted; residual in K-9); CREATE3 squatting mitigated
   (residual: deployer-key continuity); withdrawal rounding/upper bound (K-8/K-1); evm pinning
   (deployment check OPEN). Everything else unchanged.
6. `audit/05-known-issues.md` — apply the fix report's statuses: K-1, K-8, K-9, K-13, K-14, K-17 →
   **Mitigated**; K-16 → **Mitigated in code** + deployment check OPEN. Rewrite those entries against
   the new code (descriptions, impact, residual — source: `REPORT-PREAUDIT-FIXES.md`; verify each
   against the actual code; update line refs + test names). K-2…K-7, K-10…K-12, K-15, K-18…K-20:
   staleness re-check only (note K-7's new cast sites V3:570/V4:356 as `uint128(L·sharesWad/1e18)`,
   still ≤ L). K-14's proof ref to `research/spot-read/findings.md` → rewrite as "internal research
   note (withheld; available on request)". §S.1/§S.2: regenerate from the fresh slither/aderyn run +
   refresh the triage table: the fixes run showed `uninitialized-local` (`_bindingShares().omitted`,
   false positive) and `divide-before-multiply` (`pullFrom` bps conversion — now GONE after the
   `WAD_PER_BPS` constant; verify in the fresh run + record actual fresh counts). §S.3 refresh.
7. `audit/06-tests-tooling.md` — fresh captured results: unit `forge test --no-match-path
   'test/fork/*'` = **83/83, 0 skipped** (run it; record the suite lines — expect vault ~67,
   Create3 ~9, research 5, UniversalRouterGuard 2); fork suites on THIS pin (maintainer rerun, one
   clean build, no interleaving): v3 **22/22** in 294 s, v4 **25/25** in 338 s — cite
   as "maintainer rerun at the pin" (implementation-session runs remain cited in
   REPORT-PREAUDIT-FIXES.md §Verification); `deterministic-address-check.sh` PASS (fresh factories,
   same deployer → same proxy `0xEAc2…da1f`). Bundle section: new bundle will be built by the
   maintainer from the refresh commit; `VERIFY_BUILD=1`; expected name `~/poolmigo-audit-<sha>.tar.gz`;
   **content policy** (withheld paths) + enforcement (.gitattributes export-ignore; make-bundle.sh
   asserts absence of withheld entries AND presence of required ones — including LICENSE). New-tests
   list from the fix report (K-8 ×3 updated/new, K-9, K-13, K-14 ×3, K-17 ×3 + renames). Mention
   `script/export-abis.sh` under tooling.
8. `.gitattributes` (repo root — already committed) — verify it bites for the audit bundle:
   `git archive HEAD -o /tmp/x.tar && tar -tf /tmp/x.tar | grep -E '^(notes/|contracts/research/|contracts/TASK_)'`
   must print NOTHING. Keep `contracts/test/research/SpotReadSandwich.t.sol` INCLUDED (test evidence;
   exclusion is the `contracts/research/` docs dir only). If a pattern doesn't bite, fix it (and the
   make-bundle.sh assertion accordingly).
9. `audit/make-bundle.sh` — keep archive mechanics/interface (args, VERIFY_BUILD); extend post-archive
   checks: assert NO `notes/`, `contracts/TASK_*.md`, `contracts/research/` entries in the archive;
   assert `LICENSE` IS present; keep existing required-entry checks. Update the header comment (policy
   + why).
10. `README.md` (repo root) — add a short `## License` section (BUSL-1.1 — see `LICENSE`; non-production
    use granted; converts to GPL-3.0-or-later on the Change Date) unless already present.
11. REGENERATE `audit/slither-current.txt` (slither 0.11.4) and `audit/aderyn-current.md` (aderyn 0.6.8)
    fresh at the pin.

LEAVE: `SECURITY_REVIEW.md`, historical slither/aderyn artifacts, `REPORT-AUDIT-PACKAGE.md` (history).
OFF-LIMITS: `contracts/{src,test,script}`, `foundry.toml`, frontend/backend/shared, git write-ops, the
fork suites (MUST NOT run — cite the maintainer numbers), dependency/network installs.

## Verification you must do
- `forge clean && forge build`; unit suite (record runner + suite lines); `forge fmt --check`.
- Dry-archive exclusion proof (command + output in the report).
- End-state check: `git diff --stat 579cb60 -- contracts/src contracts/test contracts/foundry.toml` empty.
- macOS: `shasum -a 256`; no `timeout`; forge at `$HOME/.foundry/bin`.
- Write `contracts/REPORT-AUDIT-REFRESH.md` (English): per-file summary, exclusion proof,
  slither/aderyn deltas + gate status, unit line, residual doubts.

Done = docs updated + artifacts regenerated + unit green + report written. The maintainer commits,
then builds the bundle (`make-bundle.sh`) from the refresh commit.
