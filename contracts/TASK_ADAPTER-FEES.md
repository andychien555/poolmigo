# TASK — Adapter fees view + hook policy docs (IAdapterFees)

**Status**: ready to implement (2026-10-10 night). Branch: `feat/adapter-fees` (off `feat/pons-demo-stack`, do NOT push, do NOT merge main).
**Owner decision (B/C)**: additive-only adapter interface extension. The vault, `IPositionAdapter`,
`ILiquidityAdapter`, `ISwapAdapter`, capability masks, `PlanExecutor`, and all ABI shapes stay
UNTOUCHED (the vault has 31 B EIP-170 headroom — no vault change is allowed in this task).
Execution: Claude Code (print mode). Acceptance: Hermes assistant.

## Background (owner rulings, 2026-10-10)

The Fable (`UniswapV4HookedAdapter`) class only supports fee-override hooks (FablesRamp bits 0x2080);
hookData is always empty; `HOOK_FORBIDDEN_FLAGS` 0x0F0F bans liquidity callbacks and all
`*_RETURNS_DELTA` bits (unconditional withdrawals + exact delta accounting are system invariants).
The previously accepted design: keep the interface contract stable per hook class (adapter subclasses
carry the policy), ADD one optional, backward-compatible fees view so callers can split
principal vs fees (and later detect external-reward pools), and DOCUMENT the hook policy.

## What to build

1. **`src/interfaces/IAdapterFees.sol`** — new optional interface:
   `function fees() external view returns (address[] memory tokens, uint256[] memory fees);`
   - `tokens` / `fees` are index-aligned with `position()`'s token order (stable per adapter, `[token0, token1]` in POOL order).
   - `fees[i]` = the GROSS fee part of token i (banked fees + PoolManager feeGrowthInside accrual, i.e. exactly the
     sum that `position()` nets out via the vault's perf fee). Principal and free idle are NOT included.
   - Reuse the existing internal fee math per adapter (a shared internal `_feesVector()` refactor is fine
     if it does not move sizes outside each adapter's EIP-170 margin).
2. **Implement `fees()` + ERC-165 on every adapter class present on this branch**: `UniswapV3Adapter`,
   `UniswapV4Adapter`, `UniswapV4HookedAdapter`, `UniswapV4NativeEthAdapter`. All return the same semantics.
   - `supportsInterface` must answer true for `type(IAdapterFees).interfaceId`.
   - Empty-position rule: `fees()` must behave like `position()` — never poke a zero-liquidity v4 NFT
     (`CannotUpdateEmptyPosition`); with `tokenId == 0` it returns banked fees only.
3. **Tests (unit)**: per adapter — `fees() ==` the fee part `position()` nets out; harvest settles accrual
   into the bank and `fees()` then reports the bank; empty position returns bank-only; token order matches
   `position()`. No vault/periphery behavior changes — existing suites must stay green untouched.
4. **Docs**: (a) `contracts/AGENTS.md` "Adapter audit attention" — add the hook-policy block: forbidden-mask
   rationale (unconditional exits; exact settle), fee-override class only, empty hookData, dynamic-fee caveat
   (actual fee rate hook-resolved, LP accrual still in-pool), external-rewards visibility limit (value held by
   the hook is invisible to `position()`/`fees()`; `IAdapterFees` exists for the in-band split) and the
   per-adapter EIP-170 size lines INCLUDING the new view. (b) `contracts/audit/05-known-issues.md` K-6 —
   replace the "hook-bearing v4 pools remain unsupported" phrasing with the hooked-adapter policy summary.
5. **Verification** (record in `REPORT-ADAPTER-FEES.md`): `forge clean && forge build --sizes` before/after
   (each adapter's margin delta), `script/sizes-gate.sh` green, `forge fmt --check`, unit suites green,
   fork suites green for v3/v4/hooked/native on this branch if they run at a reasonable cost — otherwise run
   at least the hooked-pool fork suite and note the rest as pre-merge items. Do NOT weaken anything to fit.

## Non-goals

- No vault/splitter/zap/PlanExecutor changes. No capability-mask changes (no `CAP_EXTERNAL_REWARDS` —
  the EIP-170 margin forbids vault growth; external-reward pools remain out of scope, disclosed by docs only).
- No hookData plumbing, no new hook classes, no interface changes to existing interfaces.
- No deployment, no broadcast, no mainnet.

## Reference

`contracts/audit/05-known-issues.md` K-6; `contracts/REPORT-UR-ROUTER.md` §8 items 1–8;
`contracts/src/adapters/UniswapV4HookedAdapter.sol` header (hook policy); EIP-170 sizes from 2026-10-10
verification: vault 24,545 (31 B), hooked 24,433 (143 B), hookless v4 24,322 (254 B), v3 23,831 (745 B),
native-eth 23,350 (1,226 B).