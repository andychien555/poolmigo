# BRIEF — Backend: deployable keeper service for the Poolmigo vault

> **Historical task brief — executed 2026-09-22** (outcome: `backend/REPORT.md`; later work in
> `REPORT-MULTICHAIN.md`). Kept for provenance, not as current instructions: its environment facts
> (a running anvil, deliverables still to write) held for that session only.
> Current conventions: root `AGENTS.md` and `backend/README.md`.

You are the backend engineer for **Poolmigo** (monorepo at `/Users/Hermes/poolmigo`).
Your workspace is **`backend/` only**. Work autonomously until the exit criteria below are met.

## Read first (in order)
1. `AGENTS.md` (repo root; plus `backend/AGENTS.md`) — project, rules, norms.
2. `contracts/README.md`; `contracts/src/interfaces/IPositionAdapter.sol`; skim `contracts/src/PoolmigoVaultUpgradeable.sol` — focus on `deployTo`, `pullFrom`, `rebalance`, `onlyKeeper`, `setKeeper`, and the views.
3. `shared/deployment.local.json` — the LIVE local stack addresses; `shared/abis/` — the ABIs.
4. `contracts/script/DemoLocal.s.sol` — exactly what the local demo stack contains (two mock adapters acting as Uniswap V3/V4 stand-ins, idle + deployed capital, seeded harvestable fees).
5. `.agents/skills/viem-integration/` — house viem patterns (Bash/TS).

## What the contract is (keeper-relevant facts)
- Keeper-gated: `deployTo(IPositionAdapter adapter, uint256[] amounts)` — moves vault idle tokens into a whitelisted adapter. **`amounts` must be aligned to the adapter's own `position()` token order** (not the vault's registry order). Reverts if amounts exceed idle, adapter unregistered, or `rebalancePaused`.
- Keeper-gated: `pullFrom(IPositionAdapter adapter, uint256 sharesBps)` — pulls `sharesBps / 10_000` (1..10_000) of a registered position back into the vault, in kind; the destination is always the vault. Together with `deployTo` it expresses range/venue moves. Blocked while `rebalancePaused`.
- Keeper-gated: `rebalance()` — harvests ALL adapters, skims the performance fee in kind per token to the treasury.
- Owner-only — the keeper never calls these (a keeper that can is holding the wrong key): `addAdapter`, `removeAdapter`, `setKeeper`, `setRebalancePaused`, `setPerformanceFeeBps`, `setTreasury`, `setMaxTotalSupply`, `emergencyUnwind`, upgrades.
- Views: `tokens()`, `totalTokens()`, `adapters()`, `adapterCount()`, `isKeeper(addr)`, `rebalancePaused()`, `performanceFeeBps()`, `treasury()`, `balanceOf(addr)`; adapters expose `position() → (tokens[], amounts[])`, `dex()`, `poolId()`.
- Local stack: Anvil `http://127.0.0.1:8547`, chain id 46630; vault and adapter addresses are in `shared/deployment.local.json` (read them from there, don't copy them). Keeper account = anvil #1 `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`, key `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` (standard public Anvil test key — **LOCAL ONLY**).

## Deliverable — a keeper service you could actually deploy
Node 20+ / TypeScript / viem v2. Suggested structure (adapt as it makes sense):
`src/{config.ts, chain.ts, logger.ts, state.ts, vault.ts, policy.ts, keeper.ts, cli.ts}`, `test/`, `Dockerfile`, `docker-compose.yml`, `.env.example`, `README.md`, plus your `REPORT.md`.

**Tick behaviour** (single process, interval loop):
1. **Preflight**: `isKeeper(address)` must be true (else abort with a clear error); if `rebalancePaused`, skip deploy actions with an explicit reason.
2. **Read state**: vault basket tokens, vault idle balance per token (ERC-20 `balanceOf(vault)`), adapters + their `position()`s.
3. **Policy** (deterministic pure functions — unit-testable): keep `TARGET_IDLE_BPS` (default e.g. 2000 bps) of the total per-token holding idle; deploy the excess across adapters by `ADAPTER_WEIGHTS` (default equal), bounded by `MAX_DEPLOY_PER_TICK_BPS` (per tick); skip when excess is zero / below `MIN_DEPLOY_AMOUNT_RAW`; produce per-adapter amount vectors **aligned to that adapter's `position()` token order**.
4. **Simulate before send**: `simulateContract` every intended call; log intended actions. `DRY_RUN` defaults to **true** — in dry-run, stop here.
5. **Execute** (only when enabled): send txs via viem walletClient, wait receipts, log hashes/gas; then **verify post-conditions** by re-reading positions — log a WARN with details if the observed delta ≠ intent.
6. **Rebalance tick**: when `REBALANCE_INTERVAL_SEC` has elapsed since the last successful one, call `rebalance()` (harvest).
7. **State file** (`STATE_FILE`, default `.keeper-state.json`): last-run / last-rebalance timestamps + last tx hashes; atomic writes; survives restarts.
8. **Robustness**: per-tick error catching (a failed tick never crashes the loop), exponential backoff on RPC failures, graceful SIGINT/SIGTERM shutdown, structured JSON logs (`LOG_LEVEL`).

**Config** (env; `.env.example` documents every var): `RPC_URL`, `CHAIN_ID`, `VAULT_ADDRESS` (each overrides the registry `shared/deployments.json` + its `deployment.local.json` overlay; chain = `CHAIN_ID` > local entry > first deployed, and a `planned` chain is refused unless env supplies chain/rpc/vault — see `src/registry.ts`), `KEEPER_PRIVATE_KEY` (local demo only; also support `KEEPER_KEY_FILE`; document keystore/remote-signer for production — never log the key), `DRY_RUN` (true), `TICK_INTERVAL_SEC` (60), `TARGET_IDLE_BPS` (2000), `ADAPTER_WEIGHTS` (equal), `MAX_DEPLOY_PER_TICK_BPS` (5000), `MIN_DEPLOY_AMOUNT_RAW` (0), `REBALANCE_INTERVAL_SEC` (86400), `STATE_FILE`, `LOG_LEVEL` (info).
**CLI**: `pnpm tick` (one tick), `pnpm start` (loop); `--dry-run` / `--execute` override env.

## Tests & evidence (required)
- **Unit** (vitest): policy math (idle split, weights, caps, thresholds, adapter token-order alignment incl. a reordered adapter token list), interval gating, config parsing/defaults.
- **Integration (against the live anvil)** — skip gracefully if the RPC is unreachable; otherwise run them against the live anvil and paste the real output:
  a) dry-run: intended actions match expectation;
  b) execute: one real `deployTo` moves the intended amounts (assert adapter `position()` grew by exactly the sent amounts, within rounding);
  c) `rebalance()`: seed fees via `adapter.simulateFees(...)` (permissionless on the mock), call `rebalance()`, assert harvested totals and fee = 10% to the treasury (read `performanceFeeBps()` — 1000 on the local stack).
- `pnpm install`; `pnpm build`; `pnpm test` must pass.

## Deployment artifacts
- **Dockerfile**: multi-stage (deps → build → runtime), `node:20-alpine`, non-root user, `CMD ["node","dist/cli.js","run"]`.
- **docker-compose.yml**: keeper service, `env_file`, and a commented example for reaching host anvil (`extra_hosts: ["host.docker.internal:host-gateway"]`).
- **README.md**: quick start (dry-run first!), full env reference table, deployment notes (Docker, systemd unit example, secret handling via env/secret manager — never in image or CLI), monitoring guidance (log fields, exit codes), strategy disclaimer (conservative defaults; the real strategy is off-chain quant work — this service is plumbing, not alpha).

## Rules
- Work ONLY inside `backend/`. Never modify `contracts/`, `shared/`, `frontend/`, or root files. Upstream change needs → "Requested upstream changes" in your report.
- **NO git commands.** The parent reviews and commits.
- No real keys; local anvil test keys only, marked local-only. No side effects outside the local anvil.
- TypeScript strict; avoid `any` (comment if unavoidable). Docs/code in English.
- Anvil at `http://127.0.0.1:8547` is up with the demo stack. Do NOT redeploy the contracts stack. If the chain is unreachable, note it; you may restart it with `anvil --port 8547 --chain-id 46630` **only if down** (note it in the report).

## Definition of done
- `pnpm build` + `pnpm test` clean (paste real outputs); dry-run tick output pasted; one real execute `deployTo` (+ its verification read-back) pasted; `rebalance()` harvest+fee evidence pasted.
- Dockerfile / docker-compose / README present (if Docker isn't available on this machine to test the image, say so in the report instead of silently skipping).
- `backend/REPORT.md` at the END: what was built, file map, real command outputs, decisions, limitations, requested upstream changes. Factual only — no claim without output to back it.