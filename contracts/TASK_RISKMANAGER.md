# TASK: Risk-manager role — fast pause + emergency unwind (owner is a multisig)

> Owner decision (2026-10-01): add a **third role — risk managers** — separate from keeper and owner.
> Rationale: the owner is (will be) a **multisig** and cannot react quickly; risk managers are the
> fast-reaction layer — one whitelisted address per alerting service (e.g. Hypernative) or per risk
> operator. They can **pause (one-way)** and **emergency-unwind**. They can NOT unpause, cannot move
> funds anywhere, cannot change parameters, cannot manage the registry, cannot upgrade.
> "不能 unpause" is explicit: the unpause is the multisig's deliberate post-incident action.

READ FIRST: `src/PoolmigoVaultUpgradeable.sol` (mirror `setKeeper` / `onlyKeeper` and the existing
`setRebalancePaused` / `emergencyUnwind`), `src/interfaces/IPoolmigoVault.sol` (events + errors block),
the keeper/access-control region of `test/PoolmigoVaultUpgradeable.t.sol` (~lines 900–960 and the
`…NotKeeper` revert tests), `contracts/AGENTS.md` (basket invariants — this change is access-control
only; do NOT regress anything else).

## Spec (locked — implement exactly)

1. **Storage** — in `PoolmigoVaultStorage` (ERC-7201 `poolmigo.vault.storage`) append at the **END** of
   the struct (append-only discipline), house comment style:
   `mapping(address manager => bool allowed) isRiskManager;`

2. **Role management** — owner-only, mirroring `setKeeper` exactly:
   - `setRiskManager(address manager, bool allowed) external onlyOwner` — `PoolmigoVault__ZeroAddress`
     on the zero address; emits `RiskManagerSet(manager, allowed)`.
   - `isRiskManager(address account) external view returns (bool)`.
   - Declare in `src/interfaces/IPoolmigoVault.sol`, next to `KeeperSet` / `PoolmigoVault__NotKeeper`:
     - `event RiskManagerSet(address indexed manager, bool allowed);`
     - `error PoolmigoVault__NotRiskManager();`

3. **`pause()` — NEW, one-way safety function**:
   - Allowed callers: `owner()` OR any whitelisted risk manager. Anyone else reverts
     `PoolmigoVault__NotRiskManager`.
   - Sets `$.rebalancePaused = true`. If already paused: succeed **silently** (no revert — several
     alerting services may race). Emit `RebalancePaused(true)` only when the switch actually flips.
   - Existing pause semantics unchanged: blocks `deposit` / `deployTo` / `pullFrom` / `rebalance`;
     redemptions stay open.

4. **`emergencyUnwind()`** — change `onlyOwner` to owner-or-risk-manager (new modifier, e.g.
   `onlyOwnerOrRiskManager`). Behavior otherwise IDENTICAL (sets paused + emits, pulls every adapter
   position in kind back to the vault, `nonReentrant`).

5. **`setRebalancePaused(bool)` stays `onlyOwner`** (both directions — unpause is the multisig's call).
   Everything else stays owner-only: `addToken` / `addAdapter` / `removeAdapter` / `forceRemoveAdapter` /
   `setPerformanceFeeBps` / `setKeeper` / `setMaxTotalSupply` / `setTreasury` / `_authorizeUpgrade`.

## Scope (files)

1. `src/PoolmigoVaultUpgradeable.sol` — the five points above.
2. `src/interfaces/IPoolmigoVault.sol` — the new event + error.
3. `test/PoolmigoVaultUpgradeable.t.sol` — extend the surface/access-control tests + add the new
   behavior tests (below). Existing tests must stay green: if any assertion pinned `emergencyUnwind`'s
   old `onlyOwner` revert, UPDATE it to the new error and say so in the report.
4. `REPORT-RISKMANAGER.md` — deliverables report (brief: what changed, access matrix, test evidence).
5. Do NOT touch: the upgrade example (it inherits the base — append-only keeps it valid; still RUN its
   tests), adapters, periphery, scripts, `docs/`, any `AGENTS.md`, `notes/`, `shared/` (the orchestrator
   syncs those).

## Tests to add (house style: `vm.prank` + `expectEmit` + interface selectors)

- `test_SetRiskManager` — owner flips true/false; view follows; event asserted; zero address reverts
  `PoolmigoVault__ZeroAddress`; two managers simultaneously whitelisted.
- Non-owner `setRiskManager` reverts `OwnableUpgradeable.OwnableUnauthorizedAccount`.
- `test_RiskManagerCanPause` — RM pauses (event); then `deposit`, `deployTo`, `pullFrom`, `rebalance`
  all revert `PoolmigoVault__RebalancePaused`; **redeem still works** (assert a redeem succeeds while
  paused).
- `test_PauseIdempotent` — second `pause()` (other RM or owner) does not revert; still paused.
- `test_RiskManagerCannotUnpause` — RM calls `setRebalancePaused(false)` → reverts
  `OwnableUnauthorizedAccount`; still paused.
- `test_NonRiskManagerCannotPauseOrUnwind` — a random account AND a keeper revert
  `PoolmigoVault__NotRiskManager` on both `pause()` and `emergencyUnwind()`.
- `test_RiskManagerEmergencyUnwind` — capital deployed to an adapter; RM unwinds: everything back in
  kind in the vault, adapter position empty, ends paused, event asserted.
- `test_RemovedRiskManagerLosesRights` — after `setRiskManager(rm, false)`, `pause()` reverts.
- `test_UnpauseByOwnerResumesFlows` — owner `setRebalancePaused(false)`; keeper `deployTo` works again;
  RM can pause again afterwards.

## Acceptance

- `forge build` clean (watch for the known silent-build pitfall: check the artifacts exist).
- FULL non-fork suite green: `forge test --no-match-path 'test/fork/*'` (all unit/fuzz/research/CREATE3 —
  previously 138 passing; all stay green + the new tests).
- `forge fmt --check` clean.
- Only the spec'd behavior changed (access-control); no unrelated edits (review your own diff).

## EXECUTION NOTES (orchestrator)

- Work only inside `~/poolmigo/contracts`; `export PATH="$PATH:$HOME/.foundry/bin"` if forge is not found.
- Do NOT `git commit` — leave the tree for review.
- Keep the diff minimal; no refactors, no renames beyond the spec.
- End with a concise summary: files touched, new test names, `forge test` tail (pass counts), any
  existing test you had to update and why.
