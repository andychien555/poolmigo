# TASK: Exit-zap periphery — single-share (migoLP → USDG-only) redemption

> Owner decision (2026-09-30): exit-zap ships next, "同引擎" (same machinery as zap-in). A wallet holding
> migoLP redeems to ONE output token (USDG in practice) in a single transaction: redeem in kind → sell every
> non-output leg through the SAME UniversalRouter path → deliver everything to `receiver`.
>
> SEPARATE CONTRACT, NOT an extension: `src/periphery/PoolmigoZapOut.sol` is a sibling of `PoolmigoZapIn.sol`.
> The zap-in artifact is verified and slated for deploy — do NOT touch it (no refactors, no shared-base
> extraction). Port-and-adapt the helpers, keep behavior identical.
>
> READ FIRST: `TASK_ZAPIN.md` (spec style + acceptance shape), `REPORT-ZAPIN.md` (§7 for the guard/approval
> conventions), `src/periphery/PoolmigoZapIn.sol` (the reference implementation you port from) and
> `research/zap-sandwich/findings.md` §7–§9 (the TWAP-guard geometry the sell side reuses; no composition /
> refund-channel maths here — redeem happens BEFORE any swap, so there is no vault-ratio feedback).

## Verified live facts (same set as TASK_ZAPIN.md — re-verify with `cast` if anything looks off)

- UR **2.1.2** `0x204FAca1764B154221e35c0d20aBb3c525710498` (NEVER `0x66a9893c…A8Af`). Permit2
  `0x000000000022D473030F116dDEE9F6B43aC78BA3`.
- v3 USDG/WETH fee-100 pool `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` (deepest; token0 = WETH, token1 = USDG).
- Local/demo USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6d), WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` (18d).
- v3 NFPM `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` (fork tests only).

## Vault-side facts the flow MUST respect (verified in `src/PoolmigoVaultUpgradeable.sol`)

- `redeem(uint256 shares, address receiver) returns (address[] tokens_, uint256[] amounts)`:
  - checks `balanceOf(msg.sender) >= shares` and burns from **msg.sender** — the ZAP must HOLD the shares:
    pull them from the user with `transferFrom` (user approves the zap once on migoLP), then call
    `vault.redeem(shares, address(this))`;
  - `withdrawProportional(sharesWad, receiver)` on every adapter delivers straight to `receiver` (= the zap);
  - idle slice `floor(shares * balance / totalSupply)` also to `receiver`. Delivery rounds DOWN, never up.
- `previewRedeem(uint256 shares) returns (address[] tokens_, uint256[] owedAmounts)` — documented UPPER bound
  on delivery (rounding, never above). Use it in the view; do NOT promise exactness.
- `totalTokens()` exists; `tokens()` = registry order. Shares token = the vault itself (ERC20).

## Scope (files)

1. **NEW** `src/periphery/PoolmigoZapOut.sol` — the exit-zap (spec below).
2. **NEW** `test/ZapOut.t.sol` — unit suite (real vault core + existing mocks, like `test/ZapIn.t.sol`).
3. **NEW** `test/fork/ZapOut.fork.t.sol` — live-fork e2e (real UR/Permit2/fee-100 pool + real `UniswapV3Adapter`),
   same skip-if-unreachable + plain-ERC1967Proxy patterns as `test/fork/ZapIn.fork.t.sol`.
4. **NEW** `contracts/REPORT-ZAPOUT.md` — deliverable report.
5. You MAY extend `test/mocks/MockPermit2Router.sol` / `test/mocks/MockV3Pool.sol` ADDITIVELY if the sell
   direction needs it — afterwards `test/ZapIn.t.sol` must still be green (prove it in the report).

OFF-LIMITS: `src/PoolmigoVaultUpgradeable.sol`, `src/interfaces/*`, `src/adapters/*`, `src/periphery/PoolmigoZapIn.sol`,
`test/ZapIn.t.sol`, `test/fork/ZapIn.fork.t.sol`, `script/*`, `AGENTS.md` (all levels), `notes/`, `audit/`,
`docs/`, `frontend/`, `backend/`, `research/`, `legacy/`. No git operations. Do NOT touch the running demo stack
(anvil on port 8547) or `shared/deployment.local.json`.

## Contract spec — `PoolmigoZapOut`

Constructor `(address ur, address permit2, address owner)` — same wiring checks as `PoolmigoZapIn` (router code,
`V3_POSITION_MANAGER()` → `factory()` anchor, Permit2 code, typed errors). Not upgradeable.

Owner registry: `registerVault` / `disableVault` / and routes `setRoute(tokenIn, tokenOut, swapFee, refPool,
twapWindow, maxSlippageBps, maxDeviationBps)` — PORT ALL of it from `PoolmigoZapIn.sol` unchanged (same checks:
canonical pool via `FACTORY.getPool`, `fee` match, `observationCardinality > twapWindow`, same defaults/bounds,
zero = default, one route per ordered pair). For the exit direction the owner registers e.g.
`setRoute(WETH, USDG, 100, 0x52e65B17…71Ca, 600, 50, 50)`.

Entry point:

```solidity
function zapRedeem(
    address vault,        // must be registered
    address tokenOut,     // must be a CURRENT vault basket token (USDG in practice)
    uint256 shares,       // migoLP pulled from msg.sender (approve the zap once)
    uint256 minAmountOut, // caller's bound on TOTAL tokenOut delivered to receiver (non-zero)
    uint16 slippageBps,   // 0 = route default; else must be <= every existing route's maxSlippageBps
    address receiver      // proceeds recipient; shares come from msg.sender
) external nonReentrant returns (uint256 amountOut, uint256[] memory delivered);
```

And the view for the FE:

```solidity
function previewRedeem(address vault, address tokenOut, uint256 shares, uint16 slippageBps)
    external view returns (address[] memory tokens, uint256[] memory expectedSold,
                           uint256 expectedAmountOut, uint256[] memory expectedPassThrough);
```

Flow (exact):

1. validate: vault registered; `tokenOut` ∈ `vault.tokens()`; `shares > 0`; `receiver != 0`;
   `minAmountOut != 0`; `slippageBps ≤ route.maxSlippageBps` for EVERY existing route from each basket token
   ≠ `tokenOut` (checked before the pull, like zap-in).
2. pull `shares` via `transferFrom(msg.sender, this)` (balance-delta budget).
3. `vault.redeem(shares, address(this))` — capture `(tokens_, amounts_)`; use it for reporting, but the
   SIZING uses the actual balance delta of each registry token (defensive; delivery is floor-rounded).
4. For each registry token `t ≠ tokenOut` with balance > 0:
   - NO route → **pass-through** (liveness over purity): keep the balance, emit `ZapPassThrough(caller, t, bal)`,
     surface it in the view. Never revert for a missing route — a user must always be able to exit.
   - Route exists → one guarded exact-in swap of the FULL balance:
     - guard once per route before its first (only) swap: TWAP read + one-sided deviation check — PORT
       `_guardRoute` UNCHANGED (the adverse direction is a property of the pair direction, not of buy/sell:
       for a `t0 → t1` leg the trade is adverse when spot tick < TWAP tick; zap-in's formula already encodes
       this). Add unit tests for BOTH orientations on the sell side.
     - `minOut = twapQuote(balance) × (1 − effectiveSlip)` — the adapters' formula, single swap per leg
       (no two-phase machinery: redeem completes before any swap, so there is no ratio coupling; do NOT port
       the sens sizing). `effectiveSlip` exactly like zap-in.
     - `minOut` floors to 0 → dust pass-through (NOT an error), same event.
     - execute via `UniversalRouterCodec.v3ExactInSingle(address(this), amount, minOut, t, swapFee, tokenOut)`
       with Permit2 two-layer approvals set to exactly `amount`, zeroed immediately after (port
       `_approvePermit2` / `_revokePermit2` unchanged); map `V3TooLittleReceived` → typed
       `ZapOut__SlippageExceeded`; balance-delta re-check ≥ minOut.
5. aggregate check: `tokenOutBal = IERC20(tokenOut).balanceOf(this)` (redeem slice + every sale's output);
   `if (tokenOutBal < minAmountOut) revert ZapOut__MinAmountOut(minAmountOut, tokenOutBal)`.
6. sweep: transfer the FULL balance of `tokenOut` and of every pass-through token to `receiver`; record
   `delivered[]` registry-aligned; every allowance layer zero; post-condition: zero balances of all registry
   tokens. `amountOut = tokenOutBal`.

Hard rules: custody never beyond the call; shares → zap (burn via redeem), proceeds hard-wired to `receiver`;
NO owner functions that move funds (no rescue/sweep); `nonReentrant`; full NatSpec; typed errors for every
branch (`ZapOut__…` naming, mirror the zap-in families: validation, session, route params, pool checks, TWAP,
deviation, slippage, min-amount-out, pass-through event). No `@custom:oz-…` strings.

## Tests

Unit (`test/ZapOut.t.sol` — real vault core + existing `MockToken` / `MockPositionAdapter`; mock router/pool as
available):

- validation: unregistered vault; tokenOut not in basket; shares/minAmountOut/receiver zero; slippage looser
  than any relevant route; tightening used exactly.
- happy path 2-token (USDG+WETH): seed vault with mocks, zapRedeem → returns in kind + swap; assert
  delivered sums, shares burned (user balance 0), receiver got tokenOut, zap zero balances, ALL allowances
  (shares→zap is transferFrom — plain ERC20 allowance; ERC20→Permit2; Permit2→router) zero after.
- multi-leg 3+ tokens (generic loop): several sells in one call.
- pass-through: a basket token with NO route → delivered as-is + event; preview matches.
- dust: a sale whose minOut floors to 0 → pass-through, no revert.
- minAmountOut: set just above achievable → `ZapOut__MinAmountOut` and nothing moved.
- deviation: spot pushed adverse beyond maxDeviationBps (mock) → typed revert BEFORE the first swap; both
  orientations (`t0→t1` and `t1→t0` legs); the favourable side is allowed.
- swap failures: `V3TooLittleReceived` typed; `shortPay` balance-delta re-check.
- preview: `expectedAmountOut` ≥ actual delivered tokenOut (upper-bound direction — the vault's own rule);
  preview reverts where zapRedeem would for pre-state reasons; equals the flow's numbers on the deterministic
  mock setup within dust.
- read the vault's `previewRedeem` UPPER-bound documented behavior: assert actual ≤ expected (never above) on
  a real-core vault.

Fork (`test/fork/ZapOut.fork.t.sol`, alias `rhc`; deposit → keeper `deployTo` a real v3 position first):

- e2e: user deposits in kind (direct vault call), keeper deploys half, user `zapRedeem` all shares → assert:
  tokenOut (USDG) delivered ≥ minAmountOut; user's migoLP balance 0; zap holds zero; second wallet path works;
  paste real `forge test` lines into the report.
- guards: same-block push → typed `ZapOut__SlippageExceeded`; push beyond maxDeviation → typed deviation
  revert; both with nothing taken (atomic).

## Acceptance commands (run from `contracts/`; paste real output in the report)

- `forge build`
- `forge test --match-path 'test/ZapOut.t.sol' -vv` — all green
- `forge test --match-path 'test/ZapIn.t.sol'` — still green (mock extensions must not regress it)
- `forge clean && forge build` then `forge test` — FULL suite green (includes both periphery suites + plugin
  suites; obey the clean-build discipline from `AGENTS.md`)
- `forge fmt --check`
- `forge test --match-path 'test/fork/ZapOut.fork.t.sol' -vv` — public RPC; occasional `connection reset` =
  re-run-once; report both attempts if so
- dead-copy guard stays green; no `0x66a9893c…` anywhere in new code.

## Report (`contracts/REPORT-ZAPOUT.md`)

Standard sections (what/why; files; evidence per acceptance command; deviations; unresolved). Same rules: NO
assertion weakening (existing expectations conflict → STOP and report), keep out-of-scope files untouched,
list every extra file, no git.
