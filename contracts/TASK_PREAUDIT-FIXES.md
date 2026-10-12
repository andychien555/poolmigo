# TASK: pre-audit fixes — K-8, K-9, K-13, K-14, K-16, K-17 (+ K-1 wording)

> Maintainer decision: fix these six self-reported items in code BEFORE the external audit. Sources: each
> item's description/status/evidence in `contracts/audit/05-known-issues.md`, and the code it cites. The
> project is oracle-free, USD-free and in-kind; every fix below must preserve the existing guarantees
> (proportional in-kind semantics, round-trip never-gains, no oracle, guards unchanged where not stated).

## K-8 — adapter withdrawal precision: bps → 1e18-scaled share
Currently `withdrawProportional(uint256 sharesBps, …)` quantises adapter slices to whole bps of supply
(shortfall < 1 bp of adapter total, a large RELATIVE loss for small redemptions). Change the fraction to
**`sharesWad` = floor(shares · 1e18 / totalSupply)**:
- Update the interface (`IPositionAdapter`) and EVERY implementer + call site: both real adapters, the
  vault (`redeem`, and the "skip when zero" condition), `previewRedeem`, any mock adapters used by tests or
  demo scripts (`grep withdrawProportional` across the repo — incl. `script/` mocks — and fix all).
- Adapters burn `floor(L · sharesWad / 1e18)` liquidity (mulDiv-style), everything else identical
  (rounding down; released amounts still measured as balance deltas).
- `previewRedeem` mirrors it: `floor(position_i · sharesWad / 1e18)`; update its NatSpec to stop claiming
  exactness — it returns an **upper bound** (exact for the idle slice and for linear adapters) — this also
  resolves K-1's wording item.
- Tests: update the pinned bps-floor expectations (e.g. `test_RedeemAcrossIdleAndTwoAdapters`, the fuzz
  tolerance `adapterHolding/10_000 + 2` → tighten to the new formula's bound) and ADD a case: a redemption
  far below 1 bp of supply (≈1e-6 of supply) lands within the documented rounding of exact pro-rata.

## K-9 — force-removal of a broken adapter
- Add `forceRemoveAdapter(address adapter)`, owner-only: swap-and-pop WITHOUT calling `position()` and
  WITHOUT requiring zero holdings; emits an event (e.g. `AdapterForceRemoved(address)`); NatSpec explains:
  a reverting `withdrawProportional` otherwise blocks EVERY redemption (and an unremovable reverting
  `position()` blocks deposits) until a UUPS upgrade — this is the recovery path; assets still held by the
  removed adapter stay there (recoverable if it works again, or via upgrade).
- `removeAdapter` semantics unchanged. Tests: registering a mock adapter that reverts on `position()`
  and on `withdrawProportional` shows deposits/redeem blocked; non-owner `forceRemoveAdapter` reverts;
  after owner call the loops work again (locker test: redeem proceeds); event asserted.

## K-13 — `PoolmigoVaultV2.initializeV2`
- Add `onlyOwner`. Keep `reinitializer(2)`. Update `test_UpgradeToV2PreservesStateAndAddsFeature` (second
  call still reverts) + add a non-owner call reverts. `script/UpgradeToV2.s.sol` unaffected (owner call).

## K-14 — dust donation must not force offers
- Goal: a faucet-dust holding (e.g. 1 wei) of a registered token must NOT force every depositor to offer
  that token; a materially-held token must keep requiring it (no dilution path).
- Preferred principled rule: a token is optional for a given deposit iff `T_i == 0`, **or** the deposit's
  proportional draw for it rounds to 0 wei (draw computed from the share the deposit obtains over the
  participating tokens; skipped tokens are excluded from the min). Require non-zero offers only for tokens
  whose draw ≥ 1 wei **when the offered amount is non-zero** — choose the exact formulation and prove:
  (1) with a 1-wei donation, deposits that omit the token succeed and their share matches the
  no-donation case to the wei; (2) on the other side of the boundary the token still forces offers;
  (3) round-trip-never-gains fuzz still passes; (4) full suite green; (5) demo-scale deposit gas within
  +10 % (else justify in the report).
- If no formulation can be shown safe, STOP: leave the code as is, document, and report with evidence.
- Update NatSpec/comments accordingly (the current "a token held by the vault is mandatory" phrasing).

## K-16 — pin the EVM version
- `contracts/foundry.toml`: `evm_version = "cancun"` (executed code needs only PUSH0/TLOAD/TSTORE/MCOPY;
  no Osaka-only opcode — see K-16 scan). Confirm `forge config --json` shows cancun; build + full suites
  pass. The deployment-checklist item (confirm RHC supports these opcodes on testnet) REMAINS OPEN —
  state it in the report, do not claim it verified.

## K-17 — CREATE3 salt squatting
- Bind the effective salt to the deployer inside `PoolmigoCreate3.deploy`: effective = `keccak256(salt ‖
  msg.sender)` (or equivalent), so a third party can no longer occupy the address the team intends for its
  documented salts. Signature stays `deploy(bytes32 salt, bytes creationCode)`.
- Consequence to document (NatSpec + `notes/NAMING.md` salt section + deploy-script comments): the address
  now depends on the deployer address — cross-chain determinism holds ONLY if the same deployer address
  deploys on every chain (this is the project's deployment practice; both salts are re-derived in scripts).
- Tests: `test_CallerAndNonceDoNotAffectAddress` is inverted for the caller (nonce still does not matter,
  caller DOES); add: an attacker deploying with the team's salt + attacker caller cannot collide with the
  team's address; the team's own (caller, salt, code) is stable across repeated runs (fresh factory).

## Constraints
- NO git operations. No new dependencies. Untouched paths keep identical behaviour/gas. `forge fmt` clean.
- Verify (record exact runner lines in the report): `forge clean && forge build`, the full UNIT suite, and
  BOTH fork suites on the live RHC fork (`test/fork/UniswapV3Adapter.fork.t.sol`,
  `test/fork/UniswapV4Adapter.fork.t.sol`) — start them early, RHC's public RPC is non-archive. Foundry is
  at `$HOME/.foundry/bin` (export PATH). macOS: no `timeout`, use `shasum`.
- Do NOT edit `contracts/audit/**` (a separate pass refreshes the package from your report). `notes/` edits
  limited to the K-17 salt section of `NAMING.md`. Report each item's proposed new `05-known-issues` status.
- Write `contracts/REPORT-PREAUDIT-FIXES.md` (English): per item — what changed, the math for K-8/K-14, new
  tests, gas notes, exact runner lines (unit + v3/v4 fork), residuals, remaining deployment-checklist
  items. Done = all three suites green + report written + `forge fmt --check` clean.