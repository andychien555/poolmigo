# TASK: P3 — `ISwapAdapter` swap capability + `executePlan` (periphery `PlanExecutor`)

## Goal

Strategy layer P3: keepers compose PLANs (ordered component ops) inside the owner's constraints,
executed in ONE transaction, funds and refunds staying in the vault. Three increments:

1. `ISwapAdapter` capability on BOTH adapters (`swapExactIn`, funded only by the vault's free idle,
   the adapter's existing swap guards apply).
2. Vault: keeper `swapExactIn` wrapper + per-adapter capability bits (derived at registration via
   ERC-165, owner-toggleable) + a frozen pin view (`positionState`) on both adapters.
3. NEW periphery `src/periphery/PlanExecutor.sol` — `executePlan(Plan)` orchestrator (the vault gets
   NO `executePlan` — EIP-170).

## Frozen decisions (build exactly these; deviations → report, don't redesign)

### 1. Swap path (vault → adapter capability → existing executor)

- `ISwapAdapter.SwapParams { address tokenIn; address tokenOut; uint256 amountIn; uint256 minAmountOut; }`
- `swapExactIn(SwapParams) external returns (uint256 amountOut)` — `onlyVault`, `nonReentrant`, on BOTH
  adapters. Flow: the vault force-approves `amountIn` to the adapter → the adapter pulls with
  `safeTransferFrom(msg.sender, …)`, runs its EXISTING guarded swap internals (immutable `SWAP_EXECUTOR`
  hop; TWAP window + `maxSlippageBps` guards), then sends the FULL output back to `msg.sender` (the vault).
  Effective min-out = stricter of `params.minAmountOut` and the adapter's own guard. No new executor work.
- Validate in the adapter: tokens ∈ the adapter's basket bindings; amountIn > 0; tokenIn != tokenOut.
- Adapter emits nothing new (the shared executor's `SwapExecuted` already records the swap).
- Vault wrapper `swapExactIn(IPositionAdapter adapter, ISwapAdapter.SwapParams calldata p)`:
  `onlyKeeper`, paused check, adapter registered, `CAP_SWAP` enabled, tokenIn/tokenOut registered,
  `amountIn > 0`, tokenIn != tokenOut; forceApprove → call → reset approval to 0; require
  `amountOut >= p.minAmountOut` (belt on the returned value); emit
  `SwapSettled(address indexed adapter, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)`.

### 2. Capability bits (vault)

- Constants `CAP_LIQUIDITY = 1`, `CAP_SWAP = 2` (uint8 mask). Storage: `mapping(address => uint8) capabilities`
  in the ERC-7201 struct.
- At `addAdapter`, DERIVE the mask (owner cannot fake support): `try IERC165(adapter).supportsInterface(type(ILiquidityAdapter).interfaceId)`
  → bit; same for `ISwapAdapter` (try/catch — a non-ERC-165 adapter gets 0 for that bit, never a revert).
- Owner `setAdapterCapability(IPositionAdapter adapter, uint8 capBit, bool enabled)`: disable = free;
  enable = re-validated via `supportsInterface` (must be true). Typed revert for bad bit / unsupported.
  View `adapterCapabilities(IPositionAdapter) returns (uint8)` + event `AdapterCapabilitySet`.
- Enforcement: `addLiquidity`/`removeLiquidity` require `CAP_LIQUIDITY`; `swapExactIn` requires `CAP_SWAP`.
  One shared typed error (e.g. `__CapabilityMissing(adapter, capBit)`).
- Both adapters implement ERC-165 via OZ `ERC165` base: `supportsInterface` true for `ILiquidityAdapter`
  and `ISwapAdapter` (plus inherited `IERC165`).

### 3. `positionState()` — the frozen pin view

- On `ILiquidityAdapter` + both adapters: `positionState() returns (uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint32 configVersion)`;
  empty position → all zeros. Keep the existing `tokenId()` getter (addition only).
- `configVersion`: storage counter starting at 1, bumped on EVERY owner config change —
  `_setRangeConstraints`, `_setTwapWindow`, `_setMaxSlippageBps`, legacy `_setRange`.

### 3b. `_setRangeConstraints` completeness clause (P3 delta — carry it here)

- A width window with NO spacing multiple inside it is equally unsatisfiable (all widths are spacing
  multiples: `minRangeTicks_ = 11, maxRangeTicks_ = 19, spacing = 10` admits no legal width). P1b2 found it
  and left it; carry the fix here.
- Add to BOTH adapters (same `__InvalidConstraints` error): reject unless
  `alignUp(minRangeTicks_, spacing) <= maxRangeTicks_`. Together with the existing `minRangeTicks_ <= box`
  clause the box is now rejected iff NO range can possibly fit it (exactly two clauses).
- This deliberately touches the `maxRangeTicks_` rule — the P1b2 boundary tests must stay green
  (spacing-1 unit cases are unaffected; check the v4 fork case arithmetically against its spacing).

### 4. `PlanExecutor` (new, `src/periphery/PlanExecutor.sol`)

```solidity
struct Pin { address adapter; uint256 tokenId; int24 tickLower; int24 tickUpper; uint128 liquidity; uint32 configVersion; }
struct Component { uint8 kind; address adapter; bytes payload; }
struct Plan { uint256 nonce; uint64 deadline; uint256 expectedTotalSupply; Pin[] pins; Component[] components; }
```

- `executePlan(Plan calldata plan) external`: `nonReentrant`; caller ∈ keepers; `block.timestamp <= deadline`.
- Pins checked UPFRONT (state at plan start), before any component: `vault.totalSupply() == expectedTotalSupply`;
  every pin must equal the live `adapter.positionState()`; ALL values equal (no tolerance); a component whose
  `adapter != address(0)` MUST appear in `pins` (coverage) — `kind 0` (Harvest) is adapter-less.
- Nonce: per-keeper monotonic mapping `nonces(address)`; require `plan.nonce == nonces[msg.sender]`;
  increment AFTER all components succeed (a revert rolls back everything incl. the counter).
- Components executed strictly IN ARRAY ORDER:
  - `0 Harvest` → `vault.rebalance()` (adapter field ignored; payload empty)
  - `1 Swap` → `vault.swapExactIn(adapter, decode(payload, ISwapAdapter.SwapParams))`
  - `2 AddLiquidity` → `vault.addLiquidity(adapter, decode(payload, ILiquidityAdapter.AddLiquidityParams))`
  - `3 RemoveLiquidity` → `vault.removeLiquidity(adapter, decode(payload, ILiquidityAdapter.RemoveLiquidityParams))`
  - `4 ClosePosition` → `vault.pullFrom(adapter, 10_000)` (payload must be empty)
  - any other kind → typed `__UnsupportedComponent`. Payloads decode into the TYPED structs above —
    never raw calldata execution.
- `planId = keccak256(abi.encode(plan))`; emit `PlanExecuted(bytes32 indexed planId, address indexed keeper, uint256 nonce)`.
- Ownable (its own owner) + `setKeeper(address,bool)` + `KeeperSet`; vault address immutable constructor arg;
  `ReentrancyGuard`; NO paused mirror (the vault enforces per call); the executor NEVER holds funds
  (no receive/fallback; nothing is transferred THROUGH it — it only makes vault calls).
- NOTE: the executor must be registered as a vault keeper for its calls to pass (`setKeeper(planExecutor, true)`
  is an owner action; tests/scripts must do it). Its own `setKeeper` governs who may call `executePlan`.

### 5. Events / ABI freeze summary

New: `SwapSettled` (vault), `AdapterCapabilitySet` (vault), `PlanExecuted` + `KeeperSet` (executor).
Additions only — NEVER change or remove an existing event signature, error name, or getter.

## Tests (all must be real assertions, no smoke)

- Unit — vault caps: derivation at `addAdapter` (ERC-165 and non-ERC-165 adapters), enable-validation
  (cannot enable unsupported), disable path, wrapper enforcement (`__CapabilityMissing`) for liq + swap,
  swap wrapper happy path (mock adapter), approval reset to 0, min-out belt.
- Unit — `positionState()` zeros/values + `configVersion` bumps on each setter (adapters as available in unit).
- Unit — PlanExecutor: order respected (recording mock vault or event trail), nonce replay/out-of-order,
  deadline, supply-pin mismatch, adapter-pin mismatch, coverage violation, unsupported kind, non-keeper,
  harvest/close dispatch shapes, decode-failure revert.
- Update test mocks: `MockLiquidityAdapter` → ERC-165 + the new views; ADD a swap-capable mock for the
  swap wrapper tests; `MockPositionAdapter` must keep working WITHOUT caps (non-ERC-165 = mask 0).
- Fork (v3 AND v4 suites): REAL `executePlan` end-to-end — e.g. Remove → Swap → Add on the real pool
  (sane floors, real executor hop), Harvest and ClosePosition variants; `swapExactIn` min-out breach
  (both sources: params floor and venue guard); `configVersion` staleness (owner set between = pins fail);
  pins mismatch; EXTEND the existing approval-trail assertions to the swap path (vault→adapter approval 0
  after; adapter leaves nothing on Permit2/UR/executor; output landed in the vault).
- Re-run ALL FOUR fork suites + the full non-fork suite. `forge fmt`. Sizes before/after.

## Budget (hard limits)

Current (post-P1b2): v3 adapter 1,710 B margin · v4 adapter **608 B** · vault 832 B · upgrade fixture 106 B
(all vs 24,576). This change realistically adds ~0.5–0.9 KB per adapter (ERC-165 + positionState + swapExactIn
+ configVersion bumps + the §3b clause) and ~0.7–1.1 KB to the vault — **v4 WILL need deep refactoring** to
fit (precedent: P1b absorbed ~3 KB of features through refactors). Refactor aggressively (shared helpers,
small errors with args, no natspec bloat); NEVER weaken or drop a check or a frozen power.
`PoolmigoVaultUpgradeExample` is TEST-ONLY and may be TRIMMED so it stays < 24,576 B (keep its purpose: a
storage-extending upgrade exercising the OZ validator). If a limit still cannot be met after honest
refactoring: STOP, list byte options, do not silently descope.

## Out of scope

- No `executePlan` in the vault. No P2 (three-way accounting) work — fee policy untouched.
- No deploy scripts, no demo-stack wiring, no ABI export, no FE/BE/`shared/`, no docs/`notes/`,
  no `AGENTS.md` (all P4).
- Do not commit. Do not touch `TASK_*`/`REPORT-*` other than writing `REPORT-EXECPLAN-P3.md`.

## Deliverable

`REPORT-EXECPLAN-P3.md` — deviations FIRST, then exact commands, size table (before/after, all five
artifacts), per-suite counts, and the frozen-surface recap (any nuance the strategy side must know).
