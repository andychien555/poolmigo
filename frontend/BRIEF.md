# BRIEF — Frontend: wire the Poolmigo vault using viem

> **Historical task brief — executed 2026-09-22** (outcome: `frontend/REPORT.md`; later work in
> `REPORT-WALLETS.md`, `REPORT-MULTICHAIN.md`). Kept for provenance, not as current instructions: its
> environment facts (a running anvil, deliverables still to write) held for that session only.
> Current conventions: root `AGENTS.md` and `frontend/README.md`.

You are the frontend engineer for **Poolmigo** (monorepo at `/Users/Hermes/poolmigo`).
Your workspace is **`frontend/` only**. Work autonomously until the exit criteria below are met.

## Read first (in order)
1. `AGENTS.md` (repo root; plus `frontend/AGENTS.md`) — project, rules, norms.
2. `notes/frontend/` — prototype brief (`CLAUDE-CODE-PROMPT.md`), PRD (`PRD-tide-prototype.md`), `MOCK-DATA-SPEC.md`: the design/product source (working docs — never published).
3. `frontend/README.md` — current prototype overview.
4. `shared/deployments.json` — the multi-chain registry; `shared/deployment.local.json` — the local stack's addresses, overlaid onto its registry entry.
5. `shared/abis/` — `PoolmigoVaultUpgradeable.json`, `MockToken.json`, `MockPositionAdapter.json`, `IPositionAdapter.json`.
6. `contracts/README.md`, `contracts/src/interfaces/IPositionAdapter.sol`, and skim `contracts/src/PoolmigoVaultUpgradeable.sol` (deposit / redeem / previewDeposit / previewRedeem / totalTokens).
7. `contracts/script/DemoLocal.s.sol` — exactly what the local demo stack contains.
8. `.agents/skills/viem-integration/` — the house viem patterns. The frontend is viem-only: skip the skill's wagmi references (`src/test/deps.test.ts` fails if wagmi comes back).

## What the contract is (and is not)
The vault is an **in-kind basket vault**:
- `deposit(address[] tokens_, uint256[] amounts_, uint256 minShares, address receiver)` — amounts are MAX offers; only the required ceil amounts get pulled; `minShares` is MANDATORY and must be non-zero (contract reverts `PoolmigoVault__ZeroMinShares` otherwise). Shares = min binding ratio across tokens.
- `redeem(uint256 shares, address receiver)` — returns each basket token in kind.
- Views: `tokens()`, `totalTokens() → (tokens[], totals[])`, `previewDeposit(tokens[], amounts[]) → (shares, requiredAmounts)`, `previewRedeem(shares) → (tokens[], owed[])`, `balanceOf(user)` = migoLP, `adapterCount()`, `adapters()`, `adapterAt(i)`, `tokens()`, `performanceFeeBps()`, `rebalancePaused()`.
- **There is NO on-chain USD value, no oracle, no APR, no staking, no TIDE, no emissions/locks/claims/buybacks.** Those prototype surfaces must keep working as clearly-labeled DEMO DATA (see next section).

## Core mission
Keep the prototype's design and product shell unchanged (cream/aqua brand, Tailwind tokens, tabular numerals, existing components, full demo flows stay usable) — but replace the fake web3 layer with **real viem wiring** for everything the chain actually provides:

1. **Wallet + chain**: `viem` only — no wagmi. Real wallet connect replacing the fake connect. Chains come from the registry `shared/deployments.json` (each entry `planned` or `deployed`; the local anvil 46630 entry is overlaid from `deployment.local.json`) — don't hard-code chain ids or RPC URLs. When the wallet is not connected, all pages still browse; personal areas show the existing empty states.
2. **Live vault data** on the vault page(s): the deployed vault (addresses from `shared/deployment.local.json`) becomes the featured *live* vault: user migoLP balance, per-token position (via `previewRedeem(userBalance)`), total basket (`totalTokens`), idle vs in-position split (vault ERC-20 balances vs adapter `position()` calls), perf fee, paused state, adapter list with `dex()`/`poolId()` labels, and (when the adapter is the mock) `deployed(i)` / `harvestable(i)` extras — call them opportunistically and ignore failures.
3. **Deposit flow (in-kind)**: per-token amount inputs with wallet balances; live `previewDeposit` → show computable shares + required per token; slippage tolerance input (default 50 bps) → `minShares = previewShares × (1 − tol)`; per-token `approve` only when allowance is insufficient, then `deposit`. Step states (approve → deposit → done), decoded custom errors on failure, success shows the actual shares received.
4. **Redeem flow**: shares input (+ Max), live `previewRedeem` breakdown per token, confirm, `redeem`.
5. **Local-demo conveniences** (visible ONLY on the local chain): "Mint test tokens" per basket token (`MockToken.mint` is public) and a small strip showing the local RPC/chain info.
6. **Data separation + honesty**: every number the chain cannot provide (APR, TIDE emissions, rewards, locks, claims, buybacks, USD TVL) stays demo data, but must be (a) isolated in ONE module (e.g. `src/demo/`) and (b) visibly tagged in the UI with a small "Demo data" badge/legend so nobody mistakes it for chain state. Keep `notes/frontend/INTEGRATION.md` current: a table mapping every prototype data source → on-chain read or demo module, and note exactly what gets 100% real.
7. **Config generation**: never hand-copy addresses. `pnpm sync:shared` reads the registry `shared/deployments.json` (the local chain's entry overlaid from `shared/deployment.local.json`) + `shared/abis/` and emits `src/config/generated.ts` (committed, so builds work standalone).

## Tests & evidence (required)
- Keep ALL existing vitest tests green. Add unit tests for new logic (amount parse/format for 6 & 18 decimals, minShares calc, basket dispatch).
- Add `scripts/e2e-local.ts` (run via `pnpm e2e:local`) using **viem directly** with anvil account #2 (address `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC`, key `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` — standard public Anvil test key, LOCAL ONLY): read vault → mint mock tokens → approve → `previewDeposit` → `deposit` (assert shares) → `previewRedeem` → `redeem` half → assert balances/totals moved accordingly. Run it against the live anvil and paste the real output in the report.
- `pnpm install` the new deps; `pnpm build` and `pnpm test` must pass.

## Rules
- Work ONLY inside `frontend/`. Never modify `contracts/`, `shared/`, root files, or other agents' dirs. If you believe an upstream change is needed, put it under "Requested upstream changes" in your report — do not make it.
- **NO git commands** (no commit/branch/checkout/stash). The parent reviews and commits.
- No secrets: only the public anvil test keys, clearly marked local-only. Never a real key.
- TypeScript strict; avoid `any` (comment if unavoidable). UI copy in English. Do NOT add component libraries.
- Anvil is already running at `http://127.0.0.1:8547` with the demo stack deployed (see `shared/deployment.local.json`). Do NOT redeploy the contracts stack. If the chain is unreachable, document it and still deliver build + offline tests.

## Definition of done
- `pnpm build` clean, `pnpm test` green, `pnpm e2e:local` green — with real pasted output.
- Dev-server instructions in `frontend/README.md` (MetaMask: add network 46630 / RPC `http://127.0.0.1:8547` / import anvil account #2; then: mint, deposit, redeem).
- `frontend/docs/INTEGRATION.md` written; `frontend/REPORT.md` written at the END with: what was built, file map, actual command outputs, decisions made, limitations, requested upstream changes. Keep it factual — no claims without the command output to back them.