# TASK — Batch 3: per-vault receipt naming + multi-vault demo stack

Date: 2026-09-24 · Scope: `contracts/**`, plus `notes/NAMING.md` and one §8 line in
`notes/PRD-v1.7.md`. Do NOT touch `frontend/`, `backend/`, `docs/`, or other `notes/` files.
No git operations. No new dependencies.

## Why

We are moving to **multiple vaults per chain** (e.g. the flagship mUSDG/mWETH basket + a
stock-pair basket with 5 stock tokens). Two blockers in the current code:

1. `initialize` hardcodes `__ERC20_init("migoLP", "migoLP")` (L170) — a second vault would carry
   the **same receipt name/symbol** on the same chain. Name and symbol must become per-vault
   initialize parameters.
2. The local demo stack deploys ONE vault and writes a flat `shared/deployment.local.json`. We need
   a **two-vault** local stack and a per-vault write schema (below) so the frontend/backend can
   render and drive both.

## 1. `PoolmigoVaultUpgradeable.initialize` — receipt name/symbol as parameters

New signature (order matters — keep `owner` first and the arrays/params in a sane order):

```solidity
function initialize(
    address owner_,
    string calldata name_,      // new
    string calldata symbol_,    // new
    address[] calldata tokens_,
    address treasury_,
    uint16 performanceFeeBps_,
    uint256 genesisShares_,
    uint256 maxTotalSupply_
) external initializer
```

- `__ERC20_init(name_, symbol_)`; decimals stay 18 (do not override).
- Reject empty (after `bytes(name).length == 0`, and also reject all-whitespace if cheap to do —
  document the rule you implement) with a NEW named error, e.g.
  `PoolmigoVault__EmptyReceiptName()` and `PoolmigoVault__EmptyReceiptSymbol()` (keep the
  `PoolmigoVault__X` naming; add to `IPoolmigoVault` and the interface file's error list).
- Everything else about the vault is unchanged: no storage-layout changes beyond the ERC20 base
  (the strings live in the ERC20 base, not our ERC-7201 struct), UUPS/`_authorizeUpgrade`,
  `_disableInitializers()`. No reinitializer is needed (no live deployments exist).
- Update every call site: `script/DeployPoolmigoVaultUpgradeable.s.sol`,
  `script/DeployDeterministic.s.sol` (add `NAME`/`SYMBOL` env reads with defaults
  `"migoLP"`/`"migoLP"`; keep the existing `SALT` mechanism), the test suite's `_initData` helper,
  and any research/legacy references that would fail to compile.

## 2. `DemoLocal.s.sol` — deploy TWO vaults, write the v2 schema

Keep everything the script does today for **vault A**, and add a second "stocks" vault:

**Vault A (unchanged behavior, values as today)**
- basket mUSDG/mWETH (shared mocks), receipt `name = "migoLP"`, `symbol = "migoLP"`
- genesis `10_000e18`, cap `500_000e18`, fee 1000 bps, keeper = anvil #1
- two mock adapters (v3/v4 stand-ins), genesis deposit `100_000e6` + `10e18`, keeper `deployTo`
  into both, `simulateFees` on both — exactly as today.

**Vault B — "stocks" (new)**
- Five NEW mock stock tokens on top of the existing mUSDG: `MockToken("Mock NVDA","mNVDA",18)`,
  `mAAPL`, `mTSLA`, `mSPY`, `mGME` (all 18 decimals).
- Basket = `[mUSDG, mNVDA, mAAPL, mTSLA, mSPY, mGME]` (6 tokens — inside `MAX_TOKENS = 8`,
  order fixed as listed).
- Receipt `name = "migoStockLP"`, `symbol = "migoStockLP"`; genesis `25_000e18`; cap `1_000_000e18`;
  fee 1000 bps; keeper = anvil #1.
- **One mock adapter per stock pair** (5 adapters, each `MockPositionAdapter` over
  `[mUSDG, <stock>]`, distinct `dex`/`poolId` strings naming the pair, e.g.
  `"mNVDA/mUSDG 0.30%"`).
- Mint to `OWNER`: enough to seed (e.g. `50_000e6` mUSDG + `100e18` of each stock); genesis deposit
  = `20_000e6` mUSDG + `10e18` of each stock.
- Mint to `DEMO_USER`: `100_000e6` mUSDG + `50e18` of each stock.
- Keeper phase: `deployTo` into two of the five adapters (e.g. `[4_000e6, 4e18]` into the NVDA
  pair, `[3_000e6, 3e18]` into the AAPL pair — sizes stay inside the idle balances), and
  `simulateFees` on both of those adapters.

**Write `../shared/deployment.local.json` in the NEW schema (this shape is the contract for
frontend/backend — keep key names exactly):**

```jsonc
{
  "version": 2,
  "chainId": 46630,
  "rpcUrl": "http://127.0.0.1:8547",
  "vaults": [
    { "key": "demo",   "label": "mUSDG / mWETH basket",
      "receipt": { "name": "migoLP", "symbol": "migoLP" },
      "vault": "0x…", "implementation": "0x…", "keeper": "0x…", "demoUser": "0x…" },
    { "key": "stocks", "label": "Stock-pair basket (5 stocks + mUSDG)",
      "receipt": { "name": "migoStockLP", "symbol": "migoStockLP" },
      "vault": "0x…", "implementation": "0x…", "keeper": "0x…", "demoUser": "0x…" }
  ]
}
```

Use `vm.serializeUint`/`serializeString`/`serializeAddress` + nested objects
(`vm.serializeAddress` returns the JSON string — chain the calls; `vm.writeJson` once). Log both
vaults, their receipt symbols and totals (mirror today's log block for each vault).

## 3. Docs (small, exact)

- `notes/NAMING.md` — new section: **per-vault receipt naming**. Rule: receipt name/symbol are
  per-vault `initialize` parameters; convention `migoLP` for the flagship basket and
  `migo{Theme}LP` for themed vaults (demo: `migoStockLP`). Salt registry table:
  `keccak256("poolmigo.vault.v1")` = flagship, `keccak256("poolmigo.vault.stocks.v1")` = stocks
  basket (one salt per vault per chain; the factory/CREATE3 rules in the contracts README still
  apply).
- `notes/PRD-v1.7.md` — one line under §8 #18: per-vault receipt naming resolved this way (the
  remaining open item is brand assets/domain).
- `contracts/README.md` — update the salt/initialize guidance: mention the new initialize
  parameters, the salt-per-vault rule, and that `DemoLocal.s.sol` now deploys two vaults.

## 4. Tests (real output required)

- `forge clean && forge build && forge test` — all existing tests green (update `_initData` and
  any name/symbol assertions; do not weaken assertions).
- NEW tests (in the main suite): custom name/symbol are stored and readable; empty name reverts;
  empty symbol reverts; a second vault deployed in the same test with a different basket +
  different receipt name coexists (assert both name/symbols and independent accounting).
- Verify the demo script end-to-end on **your own** fresh anvil: start `anvil --port 8550
  --chain-id 46630` yourself, `forge clean && forge build`, run
  `forge script script/DemoLocal.s.sol --rpc-url http://127.0.0.1:8550 --broadcast
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
  (anvil #0 — public local-only test key), then check: both vaults exist on chain with the right
  `name()`/`symbol()`/`totalSupply()`, and `jq` the written JSON for the v2 shape (two vaults,
  correct keys). Kill your anvil afterwards. **Do not touch the anvil on port 8547** (a shared dev
  chain may be running there — leave it alone).

## 5. Report

`contracts/REPORT-BATCH3.md`: what changed (file → what), the exact new initialize signature, the
JSON written by DemoLocal (paste it), test counts before/after, your judgement calls, and anything
a reviewer should check (e.g. anything that could bite the FE/BE when they adopt the v2 schema).
Do not edit this task file.
