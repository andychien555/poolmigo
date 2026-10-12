# TASK: Strategy layer P1c — extract the UniversalRouter swap machinery into a standalone swap executor

> Owner decision (2026-10-01, approved after a measured size probe). Context: adapters sit at
> 303 B (v3) / 2,290 B (v4) of EIP-170 runtime margin. Stubbing the UR swap path frees
> 1,975 B (v3) / 2,269 B (v4). Extract UR/Permit2/swap-execution from the adapters into ONE shared,
> stateless executor contract. Design record: `../notes/EXECUTION-PLANS.md` (§EIP-170 budget,
> open question 8 / phasing P1c).

## READ FIRST
- `../notes/EXECUTION-PLANS.md` (size budget + P1c)
- `src/adapters/UniswapV3Adapter.sol` — `_executeSwap`, `_swapExactIn` (dust skip), `_approvePermit2`,
  `_revokePermit2`, `Config`, constructor wiring checks, `Swapped` event
- `src/adapters/UniswapV4Adapter.sol` — `_swapExactIn` (venue switch V3_REF_POOL ↔ own v4 pool),
  `_poolKey()`, `_checkRouter`, `Swapped(..., venue)`
- `src/adapters/uniswap/IUniversalRouter.sol` (contains `UniversalRouterCodec`), `.../v4/IPoolManagerMinimal.sol` (`PoolKey`)
- Construction sites: `script/DeployAdapters.s.sol`, `script/DemoLocalFork.s.sol`, fork suites
  (`UniswapV3Adapter`/`UniswapV4Adapter`/`ZapIn`/`ZapOut` `.fork.t.sol`), `test/LiquidityOps.t.sol`
- `contracts/AGENTS.md` (build-info pitfall, size budget)

## Spec (locked)

### 1. New `src/swap/UniversalRouterSwapExecutor.sol` + `src/interfaces/ISwapExecutor.sol`
- **Stateless**: immutables only (`UNIVERSAL_ROUTER`, `PERMIT2`), no owner, no storage, no pause.
  Constructor `(address universalRouter, address permit2)`: nonzero + `code.length != 0` checks.
  `ReentrancyGuardTransient` on both ops (house pattern).
- `swapV3ExactIn(address tokenIn, uint24 fee, address tokenOut, uint256 amountIn, uint256 minOut)
  external nonReentrant returns (uint256 amountOut)`
- `swapV4ExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut)
  external nonReentrant returns (uint256 amountOut)`
- Shared flow (mirrors exactly what the adapters do today, with the executor in the adapter's seat):
  1. guards: `amountIn > 0`, `minOut > 0` (`SwapExecutor__ZeroAmount` / `SwapExecutor__ZeroMinOut`);
  2. pull `amountIn` from **msg.sender** (`safeTransferFrom`; callers approve exactly — document);
  3. `_approvePermit2(tokenIn, UR, amountIn)` (adapter-style: `forceApprove(PERMIT2)` +
     `PERMIT2.approve(tokenIn, UR, uint160(amountIn), uint48(block.timestamp))`);
  4. build the command with the EXISTING `UniversalRouterCodec`
     (`v3ExactInSingle(recipient = msg.sender, …)` / `v4ExactInSingle(_key, zeroForOne, …, recipient = msg.sender)`);
  5. `UR.execute(commands, inputs, block.timestamp)` in `try/catch`: `isTooLittleReceived(reason)` →
     `SwapExecutor__SlippageExceeded(tokenIn, amountIn, minOut)`; everything else bubbles raw;
  6. `_revokePermit2(tokenIn, UR)`;
  7. measure msg.sender's `tokenOut` balance delta, require `>= minOut` (same error);
  8. `emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut)`; return the delta.
- **Permissionless-safe by construction** (document in natspec): only msg.sender's own tokens move,
  output returns to msg.sender, nothing at rest, approvals zeroed per call. No allowlist.

### 2. Adapters (`UniswapV3Adapter`, `UniswapV4Adapter`)
- `Config` gains `swapExecutor`; zero/code checks (reuse the adapters' `__NoCode` pattern);
  stored as `SWAP_EXECUTOR` immutable.
- v3 `_executeSwap`: approve exactly `amountIn` to `SWAP_EXECUTOR` → `swapV3ExactIn(tokenIn, POOL_FEE,
  tokenOut, amountIn, minOut)` → reset the approval to 0 → `emit Swapped(...)`. Drop the in-contract
  codec use / Permit2 calls / try-catch / delta re-check (the executor owns them now).
- v4 `_swapExactIn`: KEEP the quote math, the `minOut == 0` dust skip and the venue switch; body becomes
  approve → `swapV3ExactIn(tokenIn, REF_POOL_FEE, tokenOut, …)` or `swapV4ExactIn(_poolKey(), …)` →
  reset → `emit Swapped(..., venue)`.
- KEEP the constructor venue wiring checks (`router.V3_POSITION_MANAGER()` / `_checkRouter`) — they
  validate the venue, the executor is orthogonal.
- Swap failures now surface the **executor's** typed error (`SwapExecutor__SlippageExceeded`); update
  every affected test expectation (grep `SlippageExceeded` across `test/`). Drop adapter swap errors
  that become unused if that saves bytes; document removals in the report.
- Untouched: vault, zap contracts, codec files, adapter interfaces otherwise, quotes/guards.

### 3. Construction sites — update ALL
`script/DeployAdapters.s.sol` (deploy the executor first — or take a `SWAP_EXECUTOR` env override —
then pass it into both adapter Configs; print the address), `script/DemoLocalFork.s.sol`,
`test/fork/{UniswapV3Adapter,UniswapV4Adapter,ZapIn,ZapOut}.fork.t.sol` setUps (deploy the REAL
executor against the real UR/Permit2), `test/LiquidityOps.t.sol` (real executor over the mocks —
`MockPermit2Router` doubles as permit2 + router). Extend `MockPermit2Router` only if needed.

### 4. Tests
- New `test/SwapExecutor.t.sol` (unit): guards (zero amount / zero minOut); happy path (pulls only the
  caller's tokens; output back to the caller; Permit2 zeroed after; return = delta); `minOut`
  unreachable → `__SlippageExceeded`; **rogue-caller safety** (a third party calling with its own
  tokens moves nothing else — e.g. victim's balances untouched, executor holds nothing after).
- All existing suites stay green: 171 unit (updated expectations only where revert types moved),
  fork v3 33, fork v4 25, zap 2+2 — the fork suites are the end-to-end integration proof of the
  executor (real UR, real Permit2).
- Optional +1–2 executor smoke cases in the v3 fork suite (EOA caller swaps own tokens directly).
- Sizes: report the before/after table (`forge build --sizes`); expect v3 ≤ 22,750 B and
  v4 ≤ 20,550 B runtime. Note the swap-gas delta from the fork runs (an extra call hop is expected).

### 5. Docs
- `../notes/DEPLOY-RHC.md`: new step — deploy the executor BEFORE the adapters (regular CREATE is
  fine; it carries no privileges; adapters wire it immutably ⇒ replacing it means adapter redeploys.
  CREATE3 remains an option if we ever want a fixed address).
- No `shared/` ABI regeneration, no FE/BE, no AGENTS.md (orchestrator handles those later).

## Verification
1. `forge fmt --check`.
2. `forge clean && forge build --sizes` — record the table (LAST compile before plugin-using runs).
3. `forge test --no-match-path 'test/fork/*'` → 171 + new executor tests, 0 failed.
4. Fork suites re-run — each with its own `forge clean` first: v3 33 (MUST run, not skip; the frozen
   demo stack `http://127.0.0.1:8547` is a warm fallback for `rhc`), v4 25, zap 2 + 2.
5. `slither . --config-file slither.config.json` — exit 0, no High (the executor joins the surface).

## REPORT-EXECPLAN-P1C.md
Deviations first, then: files/wiring summary, sizes before→after per contract, test counts run
(exact commands), gas deltas observed, any removed errors, open items. Do NOT commit.
