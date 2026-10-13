# TASK: fork demo — the local dev stack runs REAL Uniswap V3/V4 adapters (RHC fork)

> Created 2026-09-30 by the orchestrator. Executed by one agent. Goal: the local demo the frontend
> and keeper operate stops being all-mock: **anvil :8547 becomes a fork of Robinhood Chain (4663)
> with chain id 46630**, the flagship vault runs the REAL `UniswapV3Adapter` + `UniswapV4Adapter`
> against the real RHC pools, and frontend + backend keep working end to end.

Repo root: `/Users/Hermes/poolmigo`. Read `AGENTS.md` (root + `contracts/`, `frontend/`, `backend/`)
FIRST — conventions, pitfalls and commands live there. Addresses: `notes/RHC_ADDRESSES.md`
(never invent an address). This brief pins the decisions; the code is the truth for details.

## What changes (and what must NOT)

NEW/changed:
- `contracts/script/DemoLocalFork.s.sol` — NEW sibling of `DemoLocal.s.sol` (do NOT modify
  `DemoLocal.s.sol`; the all-mock path stays for offline testing).
- A funding/runbook step (a small shell helper + docs; e.g. `contracts/script/fork-demo-up.sh` or
  documented `cast` steps in the script header — your call, but it must be repeatable).
- `shared/deployment.local.json` — same v2 schema + TWO new OPTIONAL root fields: `"fork": true`
  and `"mintable": false` (v2 stays v2 — do NOT bump the version; readers treat absence as
  fork=false, mintable=true). Written by BOTH scripts (mock one writes mintable=true/fork=false or
  just omits them — pick ONE convention and apply it in both).
- `frontend/scripts/registry.ts` (+ its tests) — accept the two new root keys (`LOCAL_KEYS` is
  strict; unknown keys are rejected — and `backend/src/registry.ts` restates these rules: keep the
  two in step, exactly as both AGENTS.md say).
- `frontend/src/components/live/LocalDevPanel.tsx` — the MINT section only makes sense where
  `MockToken.mint` is public. Gate it on the new flag (`mintable === false` ⇒ hide the mint rows,
  keep the info card, explain the fork funds wallets at deploy time). RPC strip etc. unchanged.
- `frontend/scripts/e2e-local.ts` — stack-agnostic: with `mintable === false` the DEFAULT vault's
  tokens are REAL (minting is impossible) → assert the wallets were funded instead, keep every core
  assertion (preview→deposit→redeem→totals). The `stocks` vault keeps its mock flow (its tokens stay
  MockToken, mintable on the fork too).
- `backend` — `src/registry.ts` accepts the new keys; tests adapted ONLY where they mint/assume mock
  tokens for the DEFAULT vault (prefer asserting existing balances). Never weaken core assertions.
- Docs: a short "fork demo" runbook in `contracts/README.md` (+ one line in `frontend/README.md`).

Do NOT touch: `contracts/src/**` (vault, adapters), `contracts/test/**` (incl. `test/fork/`),
`contracts/script/DemoLocal.s.sol`, `MockToken`/`MockPositionAdapter`, `AGENTS.md` files (the
orchestrator updates those).

## The stack

- Anvil: `anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 46630 --host 0.0.0.0
  --port 8547`. You OWN this process: kill the current plain anvil on :8547 (`lsof -i :8547`), start
  the fork one with nohup so it survives your session, keep it running at the end. Do NOT kill the
  Vite dev server on :5173.
- Funding (before the forge script): the fee-100 pool `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
  holds real USDG + WETH. Impersonate it (`anvil_impersonateAccount` + `anvil_setBalance` for gas),
  ERC20-transfer working balances to OWNER / DEMO_USER (and KEEPER if needed), then
  `anvil_stopImpersonatingAccount`. Verify every anvil dev account you use has ETH for gas
  (`cast balance`) — set it if the fork left them empty.
- TWAP trick (REQUIRED before deploys): the adapters guard `spot ≈ TWAP`. On a frozen fork, advance
  the clock one window: `cast rpc evm_increaseTime 1800` + `cast rpc evm_mine`. This makes the v3
  pool's 1800 s TWAP equal its spot (same trick the fork tests use with `vm.warp`). Do this AFTER
  funding, BEFORE the forge script.
- `forge clean && forge build` immediately before the script (OZ plugin build-info pitfall — see
  contracts/AGENTS.md).

## The deployment (`DemoLocalFork.s.sol`, run with anvil #0 key, keeper phase with anvil #1 key)

Vaults (keep the multi-vault demo, same receipt names):
1. `demo` / `migoLP` — basket `[USDG, WETH]` = the REAL RHC tokens
   (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`).
   Adapters: the REAL `UniswapV3Adapter` on the fee-100 pool (`0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`,
   NFPM `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`, SwapRouter02 `0xCaf681a66D020601342297493863E78C959E5cb2`)
   AND the REAL `UniswapV4Adapter` (poolKey fee 500 / tickSpacing 10 / hooks 0, POSM
   `0x58daec3116aae6D93017bAAea7749052E8a04fA7`; its reference + execution venue is the same v3
   fee-100 pool). Owner = anvil #0, keeper = anvil #1. Sensible demo params (ranges ±300, window
   1800, slippage 100 bps) — mirror the fork suites.
2. `stocks` / `migoStockLP` — unchanged from `DemoLocal.s.sol` (MockTokens + MockPositionAdapters;
   they deploy fine on the fork and keep the multi-vault UI + e2e story).

Flow: genesis (owner deposits real USDG/WETH in kind → K) → keeper `deployTo` into BOTH real
adapters (real swaps + real LP positions on the fork — prove it: NFT `ownerOf` = adapter for both)
→ write `shared/deployment.local.json` (addresses, keeper, demoUser; root `rpcUrl` =
`http://127.0.0.1:8547` as the runbook writes it, then the live-demo convention sed's it to the LAN
IP — see below).

## Acceptance (real output, no fabrication)

1. Fork anvil up: `cast chain-id` = 46630, `cast block-number` sane, positions/NFT checks above.
2. Post-deploy `cast` spot-checks: `USDG.symbol() == "USDG"` (REAL token), vault `totalTokens()` > 0,
   each adapter `dex()` + `position()`, `NFPM.balanceOf(adapter) == 1` for the v3 demo adapter.
3. `pnpm sync:shared` then `pnpm test` (frontend) green — including new tests for the fork flags /
   panel gating. `pnpm e2e:local` green in fork mode (core assertions intact).
4. Backend: `pnpm test` green (adapted where mock-specific) + a live tick: `VAULT=demo pnpm tick`
   (dry-run AND once without dry-run) showing deployTo/pullFrom/rebalance operate the REAL adapters.
   Leave keeper state consistent.
5. Anvil + Vite left running on the LAN (0.0.0.0); `shared/deployment.local.json` rpcUrl set to the
   LAN IP `http://10.151.1.110:8547` for the live demo (that edit is environment state — fine to
   leave uncommitted; nothing in this task does git operations anyway).
6. `contracts/REPORT-FORK-DEMO.md` — §1 what changed, §2 decisions/flagged points, §3 test table,
   §4 REAL captured outputs (anvil/script/e2e/tick). Fill §4 BEFORE you finish.

## Rules

- Iterate in phases; run long commands in the FOREGROUND with the Bash tool timeout raised; if you
  background a run, poll it to completion. NEVER end your turn with a run pending; never report
  output you have not seen.
- The RHC RPC is rate-limited: if a step fails with connection errors, wait a moment and retry once.
- `forge clean` before any OZ-plugin script run. No fabricated output. If something cannot work,
  STOP and report it precisely rather than faking or weakening it.
- No git operations (the orchestrator reviews, verifies and commits).
