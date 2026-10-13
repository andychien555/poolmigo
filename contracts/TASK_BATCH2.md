# TASK (batch 2): genesis constant · virtual shares · supply cap · keeper pullFrom · migoLP rename

Repo: `/Users/Hermes/poolmigo` (monorepo). **Your scope: `contracts/` ONLY** — `src/`, `test/`,
`script/`, `contracts/README.md`, and the two name/symbol lines in `contracts/TASK_REFACTOR.md`.
Do NOT touch `frontend/`, `backend/`, `shared/`, `docs/`, `notes/`, or any root file. NO git operations.

Read FIRST: `CLAUDE.md` (repo root), `contracts/TASK_REFACTOR.md`, `notes/PRD-v1.7.md` (sections F1.2, F1.5),
`src/PoolmigoVaultUpgradeable.sol`, `src/interfaces/IPositionAdapter.sol`, `src/interfaces/IPoolmigoVault.sol`,
`test/PoolmigoVaultUpgradeable.t.sol`, `test/research/SpotReadSandwich.t.sol`,
`test/mocks/MockPositionAdapter.sol`, all three deploy scripts.

Locked invariants (do not regress): in-kind basket accounting; NO USD anywhere; no price reads in the
vault; redeem never depends on adapter reports; redeem works while paused; `minShares` mandatory
non-zero; `deployTo` forceApprove-then-zero; ERC-7201 namespaced storage; UUPS.

## 1. Receipt token rename → migoLP
- `__ERC20_init("migoLP", "migoLP")` (was `"Poolmigo LP"` / `"pmLP"`).
- Every comment/doc reference to the receipt token `pmLP` → `migoLP` inside `contracts/` (vault,
  `IPoolmigoVault`, `README.md`, tests, and the name/symbol lines in `TASK_REFACTOR.md`).
- Test assertions: `name() == "migoLP"`, `symbol() == "migoLP"`.
- The project name "Poolmigo" stays.

## 2. Genesis constant (decision B) + owner-gated bootstrap
- Add to the ERC-7201 struct: `uint256 genesisShares;` and `uint256 maxTotalSupply;`.
- New `initialize` signature:
  `initialize(address owner_, address[] calldata tokens_, address treasury_, uint16 performanceFeeBps_, uint256 genesisShares_, uint256 maxTotalSupply_)`
  - Revert `PoolmigoVault__ZeroGenesisShares()` if `genesisShares_ == 0`.
  - Revert if `maxTotalSupply_ != 0 && maxTotalSupply_ < genesisShares_`.
- Bootstrap branch of `_previewDeposit` (supply == 0): now ALSO requires `msg.sender == owner()`
  (revert `PoolmigoVault__GenesisNotOwner()` otherwise). Full-basket + every-amount>0 rules unchanged;
  every amount is pulled in full; **`shares = genesisShares`** (was `amounts_[0]`).
  Update the `deposit` NatSpec: genesis is the team's ONE controlled seed; its manual (off-chain,
  one-time) valuation versus `genesisShares` fixes the display scale (≈$1/share); afterwards the scale
  never changes (pure ratios). If supply ever returns to 0 (full redemption), the branch re-arms with
  the same stored K, owner-gated again.
- Public getter `genesisShares()`.

## 3. Virtual shares (donation / inflation guard)
- Add constants — start here, tune ONLY if the tests below require it, and document the final values
  and rationale in code comments: `uint256 private constant VIRTUAL_SHARES = 1e6;`
  `uint256 private constant VIRTUAL_ASSETS = 1;`
- Apply to the DEPOSIT conversion only (`deposit` + `previewDeposit`):
  - `_bindingShares`: `candidate = amounts_[i].mulDiv(supply + VIRTUAL_SHARES, totals[r] + VIRTUAL_ASSETS, Floor)`
  - `_fillRequired`: `required[i] = shares.mulDiv(totals[r] + VIRTUAL_ASSETS, supply + VIRTUAL_SHARES, Ceil)`
  - Keep: tokens with `totals[r] == 0` stay optional (offering them pulls nothing); the bootstrap branch
    does NOT use virtuals; `shares == 0` still reverts `PoolmigoVault__ZeroShares`.
- Redemption stays REAL pro-rata (`shares * balance / supply` + adapter bps flooring) — do NOT apply
  virtuals to `redeem`/`previewRedeem`.
- New tests:
  (a) donation-inflation PoC: attacker deposits normally, donates basket tokens directly to the vault
      (and/or to the adapter), victim deposits, attacker redeems — assert attacker NET cannot profit
      (net ≤ 0 within rounding) and print/document the numbers in comments.
  (b) round-trip: deposit then immediate redeem pays out ≤ deposit for both tokens (±1 unit rounding),
      asserted against real balances.

## 4. Supply cap (PRD F1.2)
- `maxTotalSupply` stored (set at init; `0` = uncapped).
- Enforce in BOTH `deposit` and `_previewDeposit` (identical revert): if `cap != 0 && totalSupply() + shares > cap`
  → revert `PoolmigoVault__SupplyCapExceeded(newSupply, cap)`. Bootstrap included.
- Owner setter `setMaxTotalSupply(uint256 newCap)`: onlyOwner; require `newCap == 0 || newCap >= totalSupply()`
  (prevents bricking deposits; document); event `MaxTotalSupplySet(oldCap, newCap)`; getter `maxTotalSupply()`.
- Tests: cap enforced on deposit AND preview; raise-then-deposit OK; set-below-supply reverts; 0 = uncapped.

## 5. Keeper `pullFrom` (close the keeper gap)
```solidity
function pullFrom(IPositionAdapter adapter, uint256 sharesBps)
    external nonReentrant onlyKeeper
    returns (address[] memory tokens_, uint256[] memory amounts)
```
- Checks: registered adapter; not paused; `1 <= sharesBps <= 10_000` else revert `PoolmigoVault__InvalidSharesBps(sharesBps)`.
- Calls `adapter.withdrawProportional(sharesBps, address(this))` — destination is HARD-WIRED to the vault,
  never a parameter (this must not become a fund-egress path).
- Emits `PulledFrom(msg.sender, address(adapter), sharesBps, tokens_, amounts)`.
- NatSpec: `pullFrom` + `deployTo` together express "pull from venue A, deploy to venue B" re-shaping
  entirely on-chain.
- Tests: keeper pulls 2500 bps → vault idle grows by the adapter's slice (before/after via `totalTokens`);
  10_000 = full; `0` and `10_001` revert; non-keeper reverts; unregistered adapter reverts; paused
  reverts; pull→`deployTo(otherAdapter)` full re-shape flow works.
- If `IPoolmigoVault` enumerates the external surface, extend it (match existing style) with `pullFrom`,
  `setMaxTotalSupply`, `maxTotalSupply`, `genesisShares`.

## 6. Scripts & fixtures
- Update EVERY `initialize` call encoding: `script/DeployPoolmigoVaultUpgradeable.s.sol`,
  `script/DeployDeterministic.s.sol` (params struct + its initialize-state check),
  `script/DemoLocal.s.sol`. Sensible demo values: `genesisShares = 10_000e18`,
  `maxTotalSupply = 500_000e18`. DemoLocal's bootstrap deposit must stay the OWNER's tx (it already is)
  and keep the same seeded amounts (100k mUSDG + 10 mWETH).
- `script/deterministic-address-check.sh`: update if it passes initialize params.
- Keep the `UpgradeToV2` path green — the storage struct changes (no live deployments exist; adjust V2
  and its test as needed, never delete the upgrade test).
- `test/research/SpotReadSandwich.t.sol` and any bootstrap-dependent test: adapt to the new bootstrap
  (owner-gated, `shares = K`), PRESERVING each test's conclusion (e.g. victim pays ≤ ε, holder captures);
  re-derive constants if needed and document what changed. NEVER delete or weaken an assertion to make a
  test pass — if a conclusion genuinely must change, stop and report instead.

## Acceptance (verify, then report honestly)
1. `forge clean && forge fmt && forge build` — zero errors.
2. `forge test -vv` — ALL tests green (the 54 pre-existing, adjusted only where behavior legitimately
   changed + your new ones). Paste the summary line and per-file counts.
3. DemoLocal smoke on a THROWAWAY anvil: `anvil --port 8599 --chain-id 46630`, then
   `forge clean && forge build` and `forge script script/DemoLocal.s.sol --rpc-url http://127.0.0.1:8599 --broadcast --private-key <anvil#0 key>`
   (the public anvil #0 key is documented in the script), confirm the success output, then kill the 8599
   anvil. Do NOT touch any anvil on :8547.
4. Write `contracts/REPORT-BATCH2.md`: file-by-file changes; new tests + evidence; EVERY pre-existing
   test you modified and exactly why; final counts; DemoLocal evidence; any deviation from this brief.
   No fabricated output — paste real commands and results; if something failed, say so plainly.

Pitfalls: `forge clean` before any OZ-plugin run (stale build-info); macOS has no `timeout` binary;
V2 reinitializer needs `Options.unsafeAllow = "missing-initializer,missing-initializer-call"` scoped to
that call; never plaintext keys beyond the documented anvil-local ones.
