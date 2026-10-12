# TASK: Zap-in periphery — single-asset (USDG-only) deposit for Poolmigo vaults

> Owner decision (2026-09-30): prepare the zap. A wallet holding ONLY the vault's quote token (USDG) must
> reach migoLP in ONE transaction. The core vault stays zero-swap (LOCKED); the zap is a periphery contract
> (`notes/SWAP-DESIGN.md`: "Zap-in … belongs to a future periphery contract" — this is it).
>
> STUDY ADOPTED (2026-09-30): `contracts/research/zap-sandwich/findings.md` landed and was re-verified by
> the orchestrator (`python3 sim.py --report` reproduces report.txt; `--selftest` PASS; fuzz seed 2
> reproduces the claimed tables). Headlines: **C1 is REFUTED** — the TWAP haircut is a budget, not a wall:
> on the live fee-100 pool any zap ≳ 55k USDG is sandwich-eligible for up to τ·A (τ = the FE's minShares
> tolerance); C3/C4 are confirmed, but ONE-SHOT sizing lets the refund channel bypass minShares in coupled
> vaults. The two-phase **"sens" sizing** (findings §13) is REQUIRED, not an optimisation. READ
> `findings.md` §11 + §13 before coding; "port the reference" below = port from `sim.py`
> (strategies `impact` + `sens`).

## Verified live facts (RHC — same set as TASK_UR-ROUTER.md; re-verify with `cast` if anything looks off)

- UR **2.1.2** `0x204FAca1764B154221e35c0d20aBb3c525710498` — USE. `0x66a9893c…A8Af` — NEVER (mainnet-wired
  dead copy; source-guarded by `test/UniversalRouterGuard.t.sol`).
- Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`.
- v3 USDG/WETH fee-100 pool (deepest venue) `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
  (study T0 re-read: live L ≈ 5.086e18 @ block 76526524 — the older 4.58e18 note was stale).
- Local/demo USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6d), WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` (18d).

## Scope (files)

1. **NEW** `src/periphery/PoolmigoZapIn.sol` — the zap contract (spec below).
2. **NEW** `test/ZapIn.t.sol` — unit suite.
3. **NEW** `test/mocks/MockPermit2Router.sol` — dual-role mock: minimal Permit2 (`approve` recording inner
   allowances / `transferFrom` honoring the two-layer model) + `IUniversalRouter.execute` handling only
   `V3_SWAP_EXACT_IN` at a configurable linear rate, and configurable to revert with the router's
   `V3TooLittleReceived` selector. It must consume allowances exactly like the real pair (outer ERC20→Permit2,
   inner Permit2→router) so approval-hygiene assertions are meaningful.
4. **NEW** `test/mocks/MockV3Pool.sol` — minimal v3 pool for the quote path: `token0/token1/fee/factory/slot0/
   liquidity/observe` with a configurable mean tick (and an `increaseObservationCardinalityNext`-style no-op if
   needed). Only the subset the zap reads/writes through.
5. **NEW** `test/fork/ZapIn.fork.t.sol` — live-fork e2e (real UR 2.1.2 + real USDG/WETH pools), skip-if-
   unreachable pattern per the existing fork suites (`try vm.createSelectFork("rhc")`).
6. **NEW** `contracts/REPORT-ZAPIN.md` — deliverable report.

OFF-LIMITS: `src/PoolmigoVaultUpgradeable.sol`, `src/interfaces/*`, `src/adapters/*`, `script/*` (unless the
report motivates a change — then STOP and report instead), `AGENTS.md` (all levels), `notes/`, `audit/`,
`docs/`, `frontend/`, `backend/`, `test/research/`, `legacy/`. No git operations. Do NOT touch or redeploy the
frozen demo stack; do NOT repoint `shared/deployment.local.json`.

## Contract spec — `PoolmigoZapIn`

Constructor `(address ur, address permit2, address owner)`. Immutables; construction coherence checks mirror
the adapters': UR has code and `IUniversalRouter(ur).V3_POSITION_MANAGER()` resolves to a contract whose
`factory()` has code (the v3 FACTORY anchor is read from there); PERMIT2 has code. The contract is NOT
upgradeable (plain, no proxy, no OZ plugin involvement).

Owner registry (typed routes — never caller-supplied addresses):

- `registerVault(address vault)` / `disableVault(address vault)`: allowlist. Registration reads
  `vault.tokens()` (staticcall) and requires it non-empty; only registered vaults are callable.
- `setRoute(address tokenIn, address tokenOut, uint24 swapFee, address refPool, uint16 twapWindow,
  uint16 maxSlippageBps, uint16 maxDeviationBps)`: one route per ordered pair. Execution pool and `refPool`
  should be the SAME pool — the deepest venue for the pair (today: v3 fee-100 USDG/WETH); `refPool`
  verified at registration through the pool's own methods (`factory() == FACTORY`, `token0/token1` match)
  AND must satisfy `observationCardinality > twapWindow` (anti-DoS: a pool whose oracle ring is shorter
  than the window lets dust tick-flips revert every zap; live pool: 10,809). Params: `twapWindow` default
  600 s, bounds [300, 1800]; `maxSlippageBps` default 50, bounds [10, 300] (below 25 is not live-readable —
  slip 10 reverts 9–41 % of the time); `maxDeviationBps` default 50.
- Caller may pass `slippageBps ≤ route.maxSlippageBps` to TIGHTEN (0 ⇒ route's value); never loosen.

Entry point:

```solidity
function zapDeposit(
    address vault,       // must be registered
    address tokenIn,     // must be a CURRENT vault basket token
    uint256 amountIn,    // pulled from msg.sender via transferFrom
    uint256 minShares,   // caller's bound (mandatory non-zero; vault re-enforces)
    uint16 slippageBps,  // 0 = route default; else must be <= route.maxSlippageBps
    address receiver     // shares recipient; REFUNDS always go to msg.sender
) external nonReentrant returns (uint256 shares, uint256[] memory refunded);
```

And a view for the FE:

```solidity
function previewZap(address vault, address tokenIn, uint256 amountIn, uint16 slippageBps)
    external view returns (address[] memory tokens, uint256[] memory offers,
                           uint256 expectedShares, uint256[] memory expectedRefunds);
```

Flow (exact):

1. validate: vault registered; `tokenIn` ∈ `vault.tokens()`; `amountIn > 0`; `receiver != 0`; `minShares != 0`.
2. pull `amountIn` (`transferFrom`; the user approves the zap once).
3. read `(registry, totals) = vault.totalTokens()`, `S = vault.totalSupply()`.
4. sizing — **two-phase "sens" (ADOPTED; do NOT implement one-shot sizing)**: port the reference algorithm
   from `sim.py` (strategy `sens`):
   a. at the pre-state `totalTokens()`, solve the per-token swap targets `s_i` for the offer vector that
      matches ratios `(T_i + VA)` using the EXACT constant-L swap inverse on the execution pool (token0
      out: `s = L(1/(1/√P − w/L) − √P)/(1 − fee)`; mirror form for token1 out; reuse the vendored
      `TickMath` / `FullMath` / `FixedPoint96`; raw pool math only — NO `decimals()`/`symbol()` reads);
   b. execute HALF of each `s_i` (phase 1);
   c. re-read `vault.totalTokens()` → T¹; extrapolate `T(λ) = T¹ + (T¹ − T⁰)·λ` (λ = top-up ÷ phase-1
      size) and re-solve the top-ups on the post-swap pool state (2–3 fixed-point passes);
   d. execute the top-ups (phase 2).
   Exclusions: tokens with `T_i == 0` are EXCLUDED from sizing (the vault pulls 0 for them; anything bought
   would only be refunded). Tokens with `T_i > 0` and no route: offer 0 and let the vault decide (it will
   revert `MissingBasketToken` if its draw is non-dust — acceptable, typed). Residual always lands in
   tokenIn (lossless refund; NEVER overshoot into a bought token).
5. swaps — per route, per phase (ADOPTED):
   - Pre-swap deviation check, ONCE per route before its first swap: revert if the bought token's spot
     exceeds its TWAP by more than `route.maxDeviationBps` ticks (one-sided — the favourable side adds no
     security; its bound is the route parameter, NOT the caller's slip, else it adds nothing).
   - Phase 1 (first leg): `minOut = twapQuote(half_s_i) × (1 − effectiveSlip)` — the adapter formula, where
     `twapQuote` = quote at the route `refPool` arithmetic-mean tick over `route.twapWindow` and
     `effectiveSlip = slippageBps == 0 ? route.maxSlippageBps : min(slippageBps, route.maxSlippageBps)`.
   - Phase 2 (top-up leg): enforce the AGGREGATE bound
     `out_phase1 + out_topup ≥ twapQuote(in_phase1 + in_topup) × (1 − effectiveSlip)` — pass the top-up a
     remainder minOut (floored at 1 wei); do NOT re-apply the full haircut per phase (that double-charges
     the swap budget).
   - Execution via `UniversalRouterCodec.v3ExactInSingle(address(this), amount, minOut, tokenIn, swapFee,
     tokenOut_i)` with Permit2 two-layer approvals set to exactly `amount` and zeroed immediately after
     (mirror the adapters' `_approvePermit2` / `_revokePermit2`); map `V3TooLittleReceived` → typed
     `ZapIn__SlippageExceeded`; balance-delta re-check ≥ minOut.
   - Dust: a leg whose minOut floors to 0 is skipped; if the vault's pro-rata draw of that token would be
     ≥ 1 raw, revert early with typed `ZapIn__AmountTooSmall` (findings §11 / T11b) — the user must never
     see the vault's generic `ZeroAmount`.
6. deposit: approve each involved token to the vault for its offer, call
   `vault.deposit(tokens_, offers_, minShares, receiver)`, zero the approvals immediately after. The vault
   pulls only `required_i ≤ offer_i` — leftovers stay in the zap.
7. sweep: transfer the zap's remaining balance of EVERY involved token (tokenIn + all outputs) to
   `msg.sender`; record `refunded[]`; approvals all zero. Post-condition: zero balances for all involved
   tokens.

Events: `ZapDeposited(caller, vault, tokenIn, amountIn, shares, receiver)`, `ZapRefunded(caller, token, amount)`,
`VaultRegistered` / `VaultDisabled`, `RouteSet`. Typed errors for every validation/branch (incl.
`ZapIn__AmountTooSmall`, `ZapIn__SlippageExceeded`, and a typed deviation-check error). Full NatSpec.
(NO `@custom:oz-…` strings anywhere in prose; contract is not upgradeable.)

Hard rules: custody never leaves zap+vault; recipients hard-wired (swap outputs → zap; refunds → msg.sender);
NO owner access to user funds (no rescue/sweep functions at all in v1); every external interaction in the
Flow section; `nonReentrant` on the entry point; state after any successful call = no residue.

## Tests

Unit (`test/ZapIn.t.sol` — new mocks + existing `MockToken` / `MockPositionAdapter` + the real vault core):

- validation: unregistered vault; tokenIn not in basket; amountIn/receiver/minShares zero/slippage-too-loose reverts.
- sizing: 2-token and 6-token baskets (generic path); skewed vault ratios; the two-phase flow — phase-1
  amounts = half of the solved targets, phase-2 = the re-solved top-ups (recompute expected in the test).
- swaps: phase-1 `minOut` passed to the mock == TWAP quote × haircut EXACT; phase-2 minOut == the AGGREGATE
  remainder (recompute expected); `V3TooLittleReceived` → typed revert; dust-skip when minOut rounds to 0.
- deviation check: spot above TWAP by > maxDeviationBps (mock) → typed revert before the first swap.
- refund/sweep: exact leftover amounts returned; post-call zero balances; refunds to `msg.sender` even when
  `receiver` differs.
- approvals: after every path — ERC20→Permit2 outer, Permit2 inner→router, ERC20→vault — all ZERO.
- tightening: caller slippage > route max reverts; else used exactly.
- `previewZap` ≈ actual within ≤ 0.1 bps on a deterministic mock setup (constant-L outputs at the pre-state;
  with sens this is accurate — findings T1 "view err").
- COUPLED-vault regression (findings T1/T5): a vault whose adapter position sits in the SAME pool the zap
  swaps through → the sens run keeps the bought-token refund ≈ 0 (assert ≤ a few bps of A; one-shot sizing
  would balloon it — this test documents the adopted behavior).
- setRoute: cardinality ≤ window rejected; param bounds enforced.
- dust: `ZapIn__AmountTooSmall` case per T11b (mock token where the skipped leg would still be demanded).

Fork (`test/fork/ZapIn.fork.t.sol`, alias `rhc`, skip-if-unreachable; keep runtime modest):

- e2e: deploy a fresh vault (USDG + WETH) on the fork + one real v3 adapter position (fee-100 deep pool,
  keeper `deployTo` a slice) → a user holding ONLY USDG runs `zapDeposit` → assert: shares minted > 0;
  `totalTokens()` sane; the user got back dust-level refunds only (bounded); the zap holds zero; a second
  zap works; a tight-slippage case reverts typed.
- Paste the real `forge test` output lines into the report.

## Acceptance commands (run from `contracts/`; paste real output in the report)

- `forge build`
- `forge test --match-path 'test/ZapIn.t.sol' -vv` — all green
- `forge test` — FULL suite green (no regressions; includes the guard suite)
- `forge fmt --check` (or `forge fmt` then clean)
- `forge test --match-path 'test/fork/ZapIn.fork.t.sol' -vv --fork-url rhc` — public RPC; an occasional
  `connection reset` (= fake revert) is a re-run-once; report both attempts if so
- dead-copy guard: existing `UniversalRouterGuard.t.sol` stays green (dead address absent from new code).

## FE guidance (for the follow-up FE phase — do NOT implement now)

- `minShares` τ default **25 bps**, allowed 10–50; NEVER derived on-chain; re-quote `previewZap`
  immediately before signing (honest 1σ drift ≈ 4 bps over ~30 s at high vol — 25 bps ≈ 6σ).
- Warn above ≈ **50k USDG** that a zap is sandwich-eligible (worst case ≈ τ·A) and suggest splitting
  across blocks (same-block splits can still be bundled — no help).
- Minimum zap ≈ **1 USDG** (below that, rounding exceeds the haircut).
- Liveness: honest reverts ≈ 0.3–0.6 % at slip 50 (calm markets); offer slip 100 when reverts cluster.

## Report (`contracts/REPORT-ZAPIN.md`)

Standard sections: what/why; files touched; evidence per acceptance command (command + real output excerpt);
deviations (every judgement call, every extra file, any canonical artifact a smoke run rewrote — with backup
notes); unresolved items. NO assertion weakening: if an existing test's expectation conflicts with this
change, STOP and report instead of editing the assertion.
