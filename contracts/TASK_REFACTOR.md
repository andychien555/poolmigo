# TASK_REFACTOR.md — Phase A: multi-asset in-kind basket refactor (CORE)

You are working in `/Users/Hermes/poolmigo` (Foundry, Solidity 0.8.34, OpenZeppelin v5.1.0 + contracts-upgradeable v5.1.0 + openzeppelin-foundry-upgrades). Branch: `refactor/in-kind-basket`.

## Context — what and why

The vault is being refactored from "USD in / USD out" (single stable asset, `positionValueUsd` scalar accounting, swaps to USD on exit) to an **in-kind, multi-asset basket model**:

- The vault's receipt token (migoLP) is a **pro-rata claim on a basket of tokens** (e.g. USDG + WETH), not a USD-denominated claim.
- **Deposits are in-kind**: the user provides the basket tokens in the same proportions as the vault holds; the vault takes only the required amounts (pro-rata min) and never swaps on deposit.
- **Redemptions are in-kind**: the user receives their pro-rata slice of every token, straight from idle balances and from each adapter — no swaps to a single asset on exit.
- **Adapters speak token vectors** (`token → amount` as parallel arrays), never USD scalars. No oracle is load-bearing for share accounting; the token balances ARE the ground truth. Price guards remain ONLY inside adapters where swaps still happen (deploy ratio-adjustment, rebalance); the deposit-pricing read is spot, protected by the enforced non-zero `minShares` (rules 2–3, `research/spot-read/`).
- **Performance fee is charged in-kind** on harvested amounts, per token.

The old adapters (`UniswapV3Adapter`, `UniswapV4Adapter`) and their fork tests are parked in `legacy/` — **do NOT touch `legacy/`**. Phase B (separate task) rebuilds them against the new interface.

Old versions of every file you will rewrite exist in git history (`git show HEAD:src/PoolmigoVaultUpgradeable.sol` etc.) and in the working tree at the start — read them first for style, errors, events, and the UUPS/ERC-7201 patterns to preserve.

## Deliverables (Phase A)

1. `src/interfaces/IPositionAdapter.sol` — REPLACE with the frozen interface below.
2. `src/interfaces/IPoolmigoVault.sol` — update errors/events to the new model.
3. `src/PoolmigoVaultUpgradeable.sol` — REWRITE per spec.
4. `src/PoolmigoVaultV2.sol` — update to extend the new core (upgrade-path proof, as before).
5. `test/mocks/` — replace the old mock with `MockPositionAdapter` (multi-token) + add `MockToken` if needed.
6. `test/PoolmigoVaultUpgradeable.t.sol` — REWRITE unit suite per the test list below.
7. `script/DeployPoolmigoVaultUUPS.s.sol` — update to the new initialize signature (keep the `--account`/no-plaintext-keys pattern).

## FROZEN interface (do not deviate)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IPositionAdapter {
    function dex() external view returns (bytes32);
    function poolId() external view returns (bytes32);

    /// @notice token→amount map of everything this adapter controls, INCLUDING uncollected fees.
    ///         Parallel arrays, index-aligned; token order is stable per adapter.
    function position() external view returns (address[] memory tokens, uint256[] memory amounts);

    /// @notice Pull `amounts[i]` of position-token[i] from the vault (approve-pull; the vault
    ///         forceApproves first) and deploy into the position. amounts is aligned to the
    ///         current position() token order.
    function deploy(uint256[] calldata amounts)
        external
        returns (address[] memory tokens, uint256[] memory deployed);

    /// @notice Send floor(sharesBps/10_000) of everything this adapter holds, in kind, to `to`.
    function withdrawProportional(uint256 sharesBps, address to)
        external
        returns (address[] memory tokens, uint256[] memory amounts);

    /// @notice Collect fees/rewards and send them in kind to the vault; return what was sent.
    function harvest() external returns (address[] memory tokens, uint256[] memory amounts);

    /// @notice Unwind this entire position in kind to `to` (emergency).
    function unwindAll(address to) external returns (address[] memory tokens, uint256[] memory amounts);
}
```

`asset()` and `positionValueUsd()` are GONE. Do not re-add them.

## Vault spec — PoolmigoVaultUpgradeable (UUPS + ERC-7201, as before)

Keep: UUPSUpgradeable, Initializable, ERC20Upgradeable (name "migoLP", symbol "migoLP"), Ownable2StepUpgradeable, ReentrancyGuardTransientUpgradeable, `_disableInitializers()` in constructor, `_authorizeUpgrade` onlyOwner, and ERC-7201 namespaced storage (`erc7201:poolmigo.vault.storage`; slot constant recomputed at the 2026-09-22 rename — no live deployments existed).

Constants: `MAX_PERFORMANCE_FEE_BPS = 3000`, `BPS_DENOMINATOR = 10_000`, `MAX_ADAPTERS = 32`, `MAX_TOKENS = 8`. migoLP decimals: 18 (do not override `decimals()`).

Storage struct (fields may be renamed/removed; nothing is deployed anywhere, no migration constraints):
```solidity
struct PoolmigoVaultStorage {
    address treasury;
    uint16 performanceFeeBps;
    bool rebalancePaused;
    address[] tokens;                          // basket registry, owner-managed, ≤ MAX_TOKENS
    mapping(address => bool) isToken;
    IPositionAdapter[] adapters;
    mapping(address => bool) isAdapter;
    mapping(address => bool) isKeeper;
}
```
REMOVE: `asset`, `tvlCap`, `zapDeviationBps` (USD-denominated — meaningless now).

### initialize
`initialize(address owner_, address[] calldata tokens_, address treasury_, uint16 performanceFeeBps_)`
- Validate: owner_/treasury_ nonzero; fee ≤ MAX_PERFORMANCE_FEE_BPS; tokens_ nonempty, length ≤ MAX_TOKENS, no zero addresses, no duplicates.
- `__ERC20_init("migoLP", "migoLP")`, `__Ownable_init(owner_)`, `__Ownable2Step_init()`, `__ReentrancyGuardTransient_init()`, `__UUPSUpgradeable_init()`.

### addToken(address token) — onlyOwner
nonzero, not already registered, length < MAX_TOKENS. Push + emit `TokenAdded(token)`. No removal function in this phase.

### deposit(address[] calldata tokens_, uint256[] calldata amounts_, uint256 minShares, address receiver) → uint256 shares
Rules (STRICT same-proportions, in-kind, no swaps):
- `nonReentrant`; receiver nonzero; not paused; `tokens_.length == amounts_.length` and > 0; no duplicate entries in tokens_ (revert `PoolmigoVault__DuplicateToken`); every entry must be registered (`PoolmigoVault__TokenNotRegistered`).
- Let `T_i = totalTokens()` amount for token i (computed BEFORE pulling), `S = totalSupply()`.
- **Bootstrap** (`S == 0`): require tokens_ to cover ALL registered tokens exactly (strict full basket); every amount > 0; `shares = amounts_[0]` (bootstrap share scale is arbitrary by design — document it). Pull every amount in full.
- **Normal** (`S > 0`): for every registered token with `T_i > 0`, the deposit MUST include it (`PoolmigoVault__MissingBasketToken` if absent) with amount > 0. Then
  `shares = min over provided tokens with T_i > 0 of floor(amount_i * S / T_i)`  (use OZ `Math.mulDiv` with `Rounding.Floor`).
  If `shares == 0` → revert `PoolmigoVault__ZeroShares`.
  For each token: `required_i = ceil(shares * T_i / S)` (`Math.mulDiv` `Rounding.Ceil`); pull ONLY `required_i` (excess is simply never pulled — no refund transfer needed); tokens with `T_i == 0` pull 0.
- **Slippage guard (mandatory)**: `minShares` MUST be non-zero — revert `PoolmigoVault__ZeroMinShares` otherwise (bootstrap included: `shares == amounts_[0]` is known upfront). If `shares < minShares` revert `PoolmigoVault__InsufficientSharesOut(minShares, shares)` BEFORE any token pull.
- `safeTransferFrom(msg.sender, address(this), required_i)` per token; `_mint(receiver, shares)`; emit `Deposited(sender, receiver, tokens_, pulledAmounts, shares)`.

### redeem(uint256 shares, address receiver) → (address[] tokens, uint256[] amounts)
- `nonReentrant`; shares nonzero; receiver nonzero; `balanceOf(msg.sender) >= shares`.
- `S = totalSupply()`; `sharesBps = floor(shares * 10_000 / S)`.
- Snapshot the idle slice per registry token BEFORE any interaction: `idleOut_i = floor(shares * idle_i / S)`.
- Burn shares FIRST (effects before interactions).
- If `sharesBps != 0`: for each adapter call `withdrawProportional(sharesBps, receiver)`, accumulate per-registry-token the amounts actually returned. **No adapter reports are read on this path** — redeem must work even when an adapter cannot report.
- Send `idleOut_i` of each token from the vault's own balance to receiver. Rounding dust stays in the vault for remaining holders (adapter bps-flooring leaves up to ~1bp of the adapter-held slice; documented, never over-delivers).
- Emit `Redeemed(sender, receiver, shares, tokens, amountsSent)`.

### deployTo(IPositionAdapter adapter, uint256[] calldata amounts) — onlyKeeper, nonReentrant
- Registered adapter; not paused; `amounts.length == adapter.position().tokens.length`; each token registered; each `amounts[i] <= vault idle balance` of that token.
- For each token: `forceApprove(token, adapter, amounts[i])`; call `adapter.deploy(amounts)`; then `forceApprove(token, adapter, 0)` on every token (cleanup).
- Emit `Deployed(keeper, adapter, tokens, amounts)`.

### rebalance() — onlyKeeper, nonReentrant, returns (address[] tokens, uint256[] harvested, uint256[] fees)
- Not paused; at least one adapter.
- For each adapter: `(t, a) = adapter.harvest()` (adapter already sent the tokens to the vault in kind). Accumulate per-registry-token totals.
- For each token: `fee = floor(amount * performanceFeeBps / BPS_DENOMINATOR)`; if fee > 0 → `safeTransfer(treasury, fee)`; emit `PerformanceFeeAccrued(treasury, tokens, fees)`.
- Emit `Rebalanced(keeper, tokens, harvested, fees)`. Return the aggregated arrays.

### emergencyUnwind() — onlyOwner, nonReentrant
- Set `rebalancePaused = true` (+ emit); call `unwindAll(address(this))` on every adapter; aggregate returned vectors; emit `EmergencyUnwound(owner, tokens, amounts)`.

### addAdapter(IPositionAdapter adapter) — onlyOwner
- nonzero; not registered; `adapters.length < MAX_ADAPTERS`; call `(t, ) = adapter.position()`: `t.length > 0`, no zero addresses, and EVERY token in `t` must be registered (`PoolmigoVault__AdapterTokenNotRegistered(adapter, token)`).
- Push + emit `AdapterAdded(adapter, adapter.dex(), adapter.poolId())`.

### removeAdapter(IPositionAdapter adapter) — onlyOwner
- Registered; `(t, a) = adapter.position()`: require every `a[i] == 0` else revert `PoolmigoVault__AdapterStillFunded(adapter, token, amount)`; swap-and-pop as before; emit `AdapterRemoved(adapter)`.

### Owner setters (keep the old ones that still apply)
`setTreasury`, `setPerformanceFeeBps` (hard cap), `setKeeper`, `setRebalancePaused`. Emit as before. Keep Ownable2Step semantics.

### Views
- `tokens()` → registry array; `isToken(address)`.
- `totalTokens()` → (address[] tokens, uint256[] amounts): per registry token = vault idle balance + Σ over adapters of the adapter's `position()` amount for that token (call each adapter's `position()` ONCE; scan in memory).
- `previewDeposit(address[] tokens, uint256[] amounts)` → (uint256 shares, uint256[] requiredAmounts) — pure math per the deposit rules, no state change.
- `previewRedeem(uint256 shares)` → (address[] tokens, uint256[] owedAmounts) — mirrors {redeem} exactly (adapter slices floored at bps + exact idle slice). Reads adapter `position()` for display only; {redeem} itself never depends on reports.
- Keep: `treasury()`, `performanceFeeBps()`, `rebalancePaused()`, `isKeeper`, `isAdapter`, `adapterCount()`, `adapterAt(uint256)`, `adapters()`.
- REMOVE: `asset()`, `tvlCap()`, `zapDeviationBps()`, `pricePerShare()`, `totalAssets()`, `previewDeposit(uint256)` old signature.

### Errors / events — IPoolmigoVault.sol
Keep the `PoolmigoVault__X` naming. Errors needed: ZeroAddress, ZeroAmount, ZeroShares, FeeTooHigh, NotKeeper, RebalancePaused, NoAdapters, TokenNotRegistered(address), TokenAlreadyRegistered(address), MaxTokensReached(uint256), DuplicateToken(address), MissingBasketToken(address), LengthMismatch, AdapterNotRegistered(address), AdapterAlreadyRegistered(address), MaxAdaptersReached(uint256), AdapterTokenNotRegistered(address adapter, address token), AdapterStillFunded(address adapter, address token, uint256 amount), InsufficientShares(uint256 held, uint256 shares).
Events needed: TokenAdded, Deposited(sender, receiver, tokens[], amounts[], shares), Redeemed(sender, receiver, shares, tokens[], amounts[]), Deployed(keeper, adapter, tokens[], amounts[]), Rebalanced(keeper, tokens[], harvested[], fees[]), PerformanceFeeAccrued(treasury, tokens[], fees[]), AdapterAdded(adapter, dex, poolId), AdapterRemoved(adapter), EmergencyUnwound(owner, tokens[], amounts[]), KeeperSet, TreasurySet, PerformanceFeeSet, RebalancePaused(bool).

## PoolmigoVaultV2.sol
Keep the established upgrade-proof pattern: extends the new core, adds `minRebalanceInterval` (own ERC-7201 namespace, new slot), `initializeV2(uint256)` as `reinitializer(2)`, `version()` returning `"2.0.0"`, owner setter for the interval. The old V2 file shows the exact pattern (and its validator pitfalls).

## Mocks + unit tests
`test/mocks/MockPositionAdapter.sol`: implements the frozen interface. Deterministic bookkeeping: `deploy` pulls via `safeTransferFrom(vault, this)` and records balances; `position()` = recorded deployed balances + harvestable fees; `withdrawProportional` sends `floor(bps/10_000)` of current balances to `to`; `harvest()` transfers the harvestable portion to the vault; `unwindAll` sends everything. Add a test helper `simulateFees(uint256[] amounts)` (mint tokens to the mock + mark harvestable). Constructor takes `(address[] tokens_, address vault_, bytes32 dex_, bytes32 poolId_)`.

Unit suite `test/PoolmigoVaultUpgradeable.t.sol` must cover (use MockToken, 6dp and 18dp):
1. initialize sets state; re-init rejected; implementation locked.
2. addToken: onlyOwner, dup/zero/cap reverts.
3. addAdapter: happy path; rejects adapter with unregistered token, dup, zero, cap.
4. deposit bootstrap: full basket, mints `amounts_[0]` shares.
5. deposit normal, exact ratio: proportional shares; ONLY required amounts pulled (assert sender balances for the excess).
6. deposit skewed ratio: min token binds; only required pulled.
7. deposit missing basket token → MissingBasketToken.
8. deposit unknown token → TokenNotRegistered; duplicates → DuplicateToken; length mismatch → LengthMismatch.
9. deposit while paused reverts; redeem while paused WORKS.
10. redeem with idle + two adapters: receiver receives the exact slice (adapter bps-floor + idle slice — assertions pinned to computed values); shares burned.
11. redeem full supply: drains idle + adapters (within dust).
12. redeem: insufficient shares / zero shares reverts.
13. rebalance: simulateFees on adapters → harvested to vault; treasury gets floor(fee×bps) per token; vault keeps the rest.
14. rebalance: not-keeper reverts; no-adapters reverts.
15. deployTo: keeper-only; approves then zeroes approvals; amount > idle reverts; length mismatch reverts.
16. removeAdapter: funded reverts; after unwind → removable; registry updated.
17. emergencyUnwind: onlyOwner; pauses; tokens back in vault; adapters emptied.
18. totalTokens sums idle + adapters.
19. upgrade V1→V2 via `Upgrades.deployUUPSProxy` / `Upgrades.upgradeProxy` with `Options.unsafeAllow = "missing-initializer,missing-initializer-call"` (same as before): state preserved (tokens, balances, shares, treasury, fee); `version() == "2.0.0"`; `initializeV2` works.

## Constraints (hard)
- Do NOT modify: `foundry.toml`, `remappings.txt`, `lib/`, `.github/`, `audit/`, `legacy/`, `AGENTS.md` (every level), `notes/RHC_ADDRESSES.md`.
- No new dependencies. OZ v5.1.0 (+upgradeable) only.
- Foundry quirk: before running tests that touch the OZ upgrades plugin, run `forge clean && forge build` (stale build-info JSONs otherwise abort with "Found multiple contracts with name X"). If you hit it, clean and re-run.
- `forge fmt` your files. NatSpec on every public/external function.
- Do NOT deploy, do NOT run forge scripts, do NOT commit, do NOT touch git state.
- Work until `forge clean && forge build` is clean AND `forge test -vv` is fully green. Iterate on failures yourself.

## Phase B requirements (LOCKED design rules — set with the product owner)

1. **No external or USD price is ever read — anywhere.** A basket token may have NO oracle price at
   all (memecoins): every token is just an (address, amount) pair in the vector. Deposit, redeem,
   fee, and deploy math must work identically for tokens with no price source.
2. The ONLY permitted price reference is the **venue pool's own state**, used solely to decompose an
   LP position into per-token amounts for `position()`. The v3 amounts come from pool state + range +
   liquidity (`amount0 = L(√pu−√p)/(√p·√pu)`, `amount1 = L(√p−√pl)`). Read the price INPUT at
   **SPOT (`slot0`)** — decision 2026-09-22 after `research/spot-read/` (exact-rational sim + 15k
   fuzz + Foundry PoC `test/research/SpotReadSandwich.t.sol`): a manipulated or lagged read can only
   make the depositor OVER-pay (`g(u,p) ≥ g(u,u)` for any read price `p` and valuation price `u`,
   in and out of range), never under-pay — no extraction exists in any direction, even at zero
   manipulation cost. The depositor's protection is the enforced non-zero `minShares`. Pool-native
   either way — zero external / third-party dependencies; never a USD valuation.
3. **No history dependency, no fail-closed mode**: `position()` reads spot — a pool with zero
   observation history serves the read from its first block (young/meme pools work immediately; no
   cardinality regime, no window registration constraint, no per-deposit `observe` gas). Documented
   residual: an in-block manipulator can make an honest deposit overpay — visible to `minShares`,
   bounded (loss ≤ `τ²·w/2` of the deposit; ≤ 0.2 bps at the default τ ≤ 1 %), captured pro-rata by
   holders; a non-holder attacker only donates swap fees. Front-ends: default τ ≤ 1 %, never widen
   silently.
4. **Swap path reads no price**: the keeper supplies the target split + minOut bounds; the adapter
   executes mechanically within those bounds.
5. No token-metadata reads (`symbol()`, `decimals()`, etc.) on basket tokens in `src/` — tokens
   with missing or nonstandard metadata must be usable.
6. **Zero-liquidity short-circuit in `position()`**: when the adapter holds no LP liquidity, report
   the adapter's token balances (incl. `tokensOwed` from the position manager) with NO price read —
   an unwound / empty adapter must always be able to report, so deposits can never stay blocked by a
   position that has nothing left to price.
7. **RETIRED (2026-09-22)**: the observation-cardinality / window-headroom registration checklist
   applied only to the time-averaged read. With the spot read (rule 2) there is no history to run
   out of and no ring-overwrite hazard. Kept for the record — do NOT reintroduce window or
   cardinality machinery.

## Status — Phase A + smoke verified (2026-09-22)

- Phase A (basket vault + vector interface + mocks + unit tests + scripts) on `refactor/in-kind-basket`; independently verified by the orchestrator: clean build, `forge test` **41/41**, `forge fmt` clean, V1→V2 upgrade proof in-suite.
- Review fix applied post-Phase-A: `redeem` no longer reads adapter reports (was `owed` via `totalTokens()`); now per-adapter bps slices + exact idle slice — a non-reporting adapter can never block redemptions. `previewRedeem` mirrors it exactly. Fuzz tolerance updated for the ≤1bp adapter-slice flooring.
- Deposit `minShares` slippage guard added (spec + code + tests; 41/41 green): bounds the share count BEFORE any token pull; reverts `PoolmigoVault__InsufficientSharesOut(minShares, shares)`; `0` = no bound.
- **Read-choice decision (2026-09-22)**: deposit-pricing read = SPOT + contract-enforced non-zero `minShares` (rules 2/3 rewritten, rule 7 retired). Basis: `research/spot-read/` (exact-rational sim, 15k seeded fuzz, `findings.md` + `report.txt`) + Foundry PoC `test/research/SpotReadSandwich.t.sol`. Verdict: no extraction exists even with free manipulation; only residual = bounded ε-griefing of loose-`minShares` depositors. Spot also removes the silent drift overpay and the history fail-closed mode of the time-averaged read.
- Live-node smoke (Anvil, chain 46630, port 8546) all green: deploy script → proxy `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`; bootstrap deposit (shares = `amounts[0]`); partial redeem (exact in-kind halves); `UpgradeToV2` script → EIP-1967 slot = `0x9a676e781a523b5d0c0e43731313a708cb607508`, `version() == "2.0.0"`, all state preserved.
- Fresh static analysis on refactored `src/`: slither 21 results / 30 contracts; aderyn 2 High / 10 Low — all benign classes (see `audit/SECURITY_REVIEW.md` addendum).
- Phase B NOT started: rewrite `UniswapV3Adapter` / `UniswapV4Adapter` to the vector interface under the LOCKED rules above.

## Acceptance / report
Report at the end, concisely:
- Files changed (paths).
- Exact final test summary line(s) from `forge test`.
- Any spec divergence or judgement call you made, and why.
- Anything you could not get green.
