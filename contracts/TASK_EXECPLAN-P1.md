# TASK: Strategy layer P1 — V3 precise liquidity (range constraints + addLiquidity / removeLiquidity)

> Owner decision (2026-10-01): issue `crypto-crazer/poolmigo#1` accepted. Owner sets the pool and the
> **constraints** (min/max tick, min/max range size); the keeper decides **how** to add liquidity
> inside that box. This task is the FIRST slice: the V3 adapter gains precise, bounds-checked
> liquidity operations + owner constraints, and the vault gains keeper-gated wrappers. V4 mirrors
> next (P1b); accounting (P2) and plan/component execution (P3) are separate. The design record is
> `../notes/EXECUTION-PLANS.md` — READ IT FIRST; the ABI shapes below are the P1 proposal to freeze.

READ FIRST: `../notes/EXECUTION-PLANS.md` (§P1, §Constraint model); `src/adapters/UniswapV3Adapter.sol`
(the whole file — `deploy()` / `_swapToRangeRatio` / `_addLiquidity` / `withdrawProportional` /
`setRange` and the house error/event style); `src/interfaces/IPositionAdapter.sol`;
`src/PoolmigoVaultUpgradeable.sol` — `deployTo` (the wrapper pattern: token-registration + idle
checks → `forceApprove` exact → adapter call → reset approve to 0 → emit) and the paused checks;
`test/fork/UniswapV3Adapter.fork.t.sol` (harness discipline: `vm.createSelectFork("rhc")`, one TWAP
window warp in `setUp`, skip-if-unreachable); `contracts/AGENTS.md` (invariants + pitfalls).

## Spec (locked — implement exactly)

### 1. `src/interfaces/ILiquidityAdapter.sol` (new)

```solidity
interface ILiquidityAdapter {
    struct AddLiquidityParams {
        int24   tickLower;     // absolute, spacing-aligned, inside the adapter's constraints
        int24   tickUpper;
        uint128 liquidity;     // raw target liquidity
        uint128 minLiquidity;  // acceptable-actual floor (caps may bind actual below target)
        uint256 maxAmount0;    // pull caps from the vault — approved, never exceeded
        uint256 maxAmount1;
        uint256 minSwapOut;    // explicit floor on the internal ratio swap (stricter-of wins)
    }
    struct RemoveLiquidityParams {
        uint128 liquidity;     // exact raw liquidity; 0 = idle-refund mode ONLY
        uint256 minPrincipal0; // floors apply to PRINCIPAL only — idle must never satisfy them
        uint256 minPrincipal1;
    }
    function addLiquidity(AddLiquidityParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 amount0Spent, uint256 amount1Spent,
                 uint256 amount0Refunded, uint256 amount1Refunded);
    function removeLiquidity(RemoveLiquidityParams calldata p)
        external
        returns (uint256 principal0, uint256 principal1, uint256 fees0, uint256 fees1,
                 uint256 idleRefunded0, uint256 idleRefunded1);
}
```

Events/errors stay in the adapter file (house style), prefixed `UniswapV3Adapter__`.

### 2. V3 adapter — owner constraints

- New state (plain vars — adapters are redeployed per environment, mainnet not deployed yet):
  `int24 public minTick; int24 public maxTick; int24 public minRangeTicks; int24 public maxRangeTicks;`
- Constructor defaults: widest legal box — `minTick` = MIN_TICK aligned up to spacing, `maxTick` =
  MAX_TICK aligned down, `minRangeTicks` = `TICK_SPACING`, `maxRangeTicks` = `maxTick - minTick`.
- `setRangeConstraints(int24 minTick_, int24 maxTick_, int24 minRangeTicks_, int24 maxRangeTicks_) external onlyOwner`:
  require: `MIN_TICK <= minTick_ < maxTick_ <= MAX_TICK`; both spacing-aligned; `0 < minRangeTicks_
  <= maxRangeTicks_`; revert `UniswapV3Adapter__InvalidConstraints`; emit
  `RangeConstraintsSet(minTick_, maxTick_, minRangeTicks_, maxRangeTicks)`.
- Constraints gate the NEW ops only — the legacy `deploy()` / `setRange` TWAP-anchored flow is
  untouched (do NOT regress its tests).

### 3. `addLiquidity` (onlyVault, nonReentrant)

- Validate: `p.liquidity > 0`; `p.minLiquidity <= p.liquidity`; bounds spacing-aligned;
  `p.tickLower >= minTick && p.tickUpper <= maxTick`; width `>= minRangeTicks && <= maxRangeTicks`.
  Errors: `UniswapV3Adapter__InvalidRange` (reuse) / new `UniswapV3Adapter__RangeOutsideConstraints`
  / `UniswapV3Adapter__UnalignedRange` — pick clear names, document in natspec.
- Position rule: live `tokenId == 0` → fresh allowed; else bounds MUST equal the live
  `(tickLower, tickUpper)` — **different bounds revert** (`UniswapV3Adapter__RangeMismatch`, message
  hints "close the position first"). Matching bounds = increase.
- Flow: compute required amounts for `p.liquidity` at spot; pull only what is needed
  (`safeTransferFrom(vault, …)`, ≤ caps); swap the surplus side toward the range ratio enforcing
  BOTH the existing TWAP/spot guard and `p.minSwapOut` (effective min = stricter; **nonzero required
  for a nonzero swap**); add (fresh → mint at the given absolute bounds, NOT `_computeRange`; live →
  increase); measure actual = liquidity added; require `actual >= p.minLiquidity`.
- Refund: transfer the op's leftover DELTA back to the vault (leave the adapter's pre-existing idle
  untouched). Returns + event `LiquidityAdded(tokenId, liquidityAdded, spent0, spent1, refunded0, refunded1)`.

### 4. `removeLiquidity` (onlyVault, nonReentrant)

- `p.liquidity == 0` → **idle-refund mode**: transfer the adapter's free idle (both tokens) to the
  vault; NO position-manager call; no NFT / fee-checkpoint change; returns `(0,0,0,0,idle0,idle1)`;
  event `IdleRefunded(idle0, idle1)`.
- Else: require `p.liquidity <= live liquidity`; `decreaseLiquidity` passing the principal floors as
  POSM `amount0Min/amount1Min` (principal-only enforcement — exactly the issue's rule); collect fees
  with the vault as recipient; principal + fees must land in the **vault** (hard-wired — never a
  parameter); report splits `(principal0, principal1, fees0, fees1, 0, 0)`; NFT retained
  (burning stays with the close path — `withdrawProportional(1e18)` today); event
  `LiquidityRemoved(tokenId, liquidity, principal0, principal1, fees0, fees1)`.

### 5. Vault wrappers (`PoolmigoVaultUpgradeable`)

- `addLiquidity(IPositionAdapter adapter, ILiquidityAdapter.AddLiquidityParams calldata p)` and
  `removeLiquidity(IPositionAdapter adapter, ILiquidityAdapter.RemoveLiquidityParams calldata p)`:
  `onlyKeeper`, `nonReentrant`, paused check (`PoolmigoVault__Paused`), `isAdapter` check, and — for
  add — both caps must be `<= idle` per token (mirror `deployTo`'s `InsufficientIdle`) with the token
  registry check via the adapter's `position()` order; `forceApprove(cap0/cap1)` → call → reset
  approvals to 0 → emit. No storage changes. Declare the wrappers + events in
  `src/interfaces/IPoolmigoVault.sol` (`LiquidityAdded(keeper, adapter, tokenId, liquidityAdded,
  spent0, spent1, refunded0, refunded1)` / `LiquidityRemoved(keeper, adapter, tokenId, liquidity,
  principal0, principal1, fees0, fees1, idleRefunded0, idleRefunded1)`), next to `Deployed`/`Withdrawn`.

### 6. Do NOT change

`deploy` / `withdrawProportional` / `harvest` / `unwindAll` / `setRange` / TWAP / slippage semantics;
vault `deposit` / `redeem` / `pullFrom` / `rebalance` / `emergencyUnwind`; FE/BE; `shared/` (ABI
re-export is orchestrated later, not in this task).

## Tests

- Unit (`test/`): constraint validation (`setRangeConstraints` reverts: unaligned, inverted,
  out-of-global); wrapper gating (not-keeper, paused, unregistered adapter, caps > idle → the exact
  revert, approve reset); zero-liquidity `removeLiquidity` plumbing via a mock. Extend
  `test/mocks/MockPositionAdapter.sol` with a minimal `ILiquidityAdapter` implementation (record the
  last params, return deterministic values, pull nothing) — or a sibling mock; keep
  `contracts/test/mocks` house style.
- Fork (`test/fork/UniswapV3Adapter.fork.t.sol` + new cases): fresh add hits target bounds and mints;
  matching-range increase; different-bounds revert; caps binding (actual < target but ≥ minLiquidity,
  refunds correct); `minLiquidity` unmet → revert; swap `minSwapOut` zero-while-swap → revert; remove
  partial (principal ≥ floors, fees reported, NFT kept); floors bind → revert; zero-mode refunds idle
  with NFT/fee checkpoints UNCHANGED; pre-existing idle untouched by add refunds. Keep all 22
  existing fork cases green; every new case fits the suite's one-TWAP-window discipline.

## Verification (run, don't claim)

`forge fmt`; `forge clean && forge build` (LAST compile before any plugin-using test run — build-info
pitfall); `forge test --no-match-path 'test/fork/*'` (existing 149 + new unit tests green); the fork
suite (`forge clean && forge test --match-path 'test/fork/UniswapV3Adapter.fork.t.sol' -vv`) — it
must RUN (not skip): the `rhc` endpoint is in `foundry.toml`; the frozen demo stack on
`http://127.0.0.1:8547` (chain 46630) is an already-warm fallback if the public RPC balks.

Write `REPORT-EXECPLAN-P1.md` (what/where, test names + counts, open items). Do NOT commit.
