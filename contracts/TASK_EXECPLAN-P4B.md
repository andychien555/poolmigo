# TASK: P4b — FE/BE wiring for P3 surface (registry tolerance + ABIs + plan builders + local plan e2e)

## Context

P3 landed (`70b0bad`) and P4a wired the deploy path (`63b0b62`): the demo stack now deploys a `PlanExecutor`
and `shared/deployment.local.json` carries `periphery.planExecutor`. **Both registries strictly reject
unknown keys** (`rejectUnknown` + `PERIPHERY_KEYS = ['zapIn','zapOut']`) — so FE and BE both FAIL on the new
file today. Also `shared/abis/` gained `PlanExecutor.json`, `UniswapV3Adapter.json`, `UniswapV4Adapter.json`
and the vault ABI was refreshed (addLiquidity/removeLiquidity/swapExactIn/setAdapterCapability/
adapterCapabilities/CAP_* + events/errors).

Run the current suites FIRST to see the failures, then fix.

## backend/

1. `src/registry.ts`
   - `PERIPHERY_KEYS` += `'planExecutor'`; `RegistryPeriphery` gains `planExecutor?: Address`.
   - Relax the "at least one" rule to accept any of zapIn/zapOut/planExecutor (update the message + header
     comment: v2-additive `periphery` = `{ zapIn?, zapOut?, planExecutor? }`).
   - Non-zero-address validation applies to planExecutor too.
2. `scripts/sync-abis.mjs` — extend `SELECTION`:
   - `vaultAbi`: add the keeper-facing P1/P3 members: `addLiquidity`, `removeLiquidity`, `swapExactIn`,
     and the events `LiquidityAdded`, `LiquidityRemoved`, `SwapSettled` (leave owner-only functions OUT —
     that's the file's stated purpose). Check the refreshed `PoolmigoVaultUpgradeable.json` for exact names.
   - NEW `planExecutorAbi` (`PlanExecutor.json`): `executePlan`, `nonces`, `isKeeper` + events
     `PlanExecuted`, `KeeperSet` (+ `KEEPER`/`MAX_COMPONENTS` consts if useful) + ALL_ERRORS. NOT `setKeeper`.
   - NEW `liquidityAdapterAbi` for plan composition/reads: source ONE of the adapter files and keep only
     members that exist in BOTH adapters' exports (verify per name against both `UniswapV3Adapter.json` and
     `UniswapV4Adapter.json`; drop any v3-only/v4-only name) — e.g. `previewAddLiquidity`,
     `rangeConstraints`, `positionState`, `tokenId`, `dex`, `position` (verify the real list from the files;
     also check what `IPositionAdapter.json` already covers). Document the choice in the report.
   - `pnpm run sync-abis`; commit-ready `src/abi/generated.ts` in the working tree.
3. NEW `src/plan.ts` + `src/plan.test.ts` — keeper-side plan builders:
   - Types mirroring `PlanExecutor`'s component kinds + typed structs EXACTLY (read
     `contracts/src/periphery/PlanExecutor.sol` for the enum kinds and each payload struct, and the vault's
     op signatures for the fields): builders `addLiquidity(...)`, `removeLiquidity(...)`, `rebalance(...)`,
     `swapExactIn(...)` returning `{ adapter, kind, payload }` with `payload` = `encodeAbiParameters` of the
     matching struct.
   - A `planId`-equivalent helper IF the contract's hash is reproducible in TS (check `PlanExecutor.sol`:
     keccak over the components — mirror it exactly and prove it against the contract in the e2e below);
     if it is not cleanly reproducible, skip it and say so.
   - Unit tests for the encoders.
4. Integration e2e against the LOCAL demo stack (frozen anvil on http://127.0.0.1:8547 — the redeploy has
   just been run; `periphery.planExecutor` + keeper #1 are wired): add a test that, AS anvil #1 (the
   executor's keeper), submits a real `executePlan` (e.g. one `AddLiquidity` component on the v3 adapter via
   the vault) and asserts: the `PlanExecuted(planId, keeper, nonce)` event, the per-keeper nonce advanced,
   and the vault/position state changed. Reuse the suite's existing local-stack plumbing (chain.ts /
   whatever the fee-volume tests use); guard it like the other local-stack tests if they guard. If a
   payload kind needs pre-set state (e.g. `deployTo` first), do it in the setup with the existing helpers.
   NO new anvil; NEVER a plaintext key beyond the world-public anvil dev keys already used by the suite.
5. Run: `pnpm test` (expect the current count 265+1skip PLUS your new tests) + typecheck/lint as the repo does.

## frontend/

1. `scripts/registry.ts`: `PERIPHERY_KEYS` += `'planExecutor'`; `RegistryPeriphery` gains
   `planExecutor?: string`; same "at least one" + non-zero rules as BE; update the header comment.
2. `scripts/sync-shared.ts`: pass `periphery.planExecutor` through where zapIn/zapOut flow (the emitted
   generated file must carry it; do NOT add new ABIs the app does not use).
3. `pnpm sync:shared` then `pnpm typecheck` + unit tests (expect 190 + your additions if any).
   Do NOT run the frontend e2e (the orchestrator runs it after you).

## Rules

- Do NOT commit. Do NOT touch contracts/ (except reading), notes/, docs/, AGENTS files, or `shared/` inputs
  themselves. FE/BE only + `backend/src/abi/generated.ts` (generated).
- The local stack on :8547 MUST stay up (never kill/restart anvil).
- macOS: no `timeout`. Foundry not needed here. pnpm only.
- Reports: `backend/REPORT-EXECPLAN-P4B.md` and `frontend/REPORT-EXECPLAN-P4B.md` (or one shared note at
  whichever path the repos use for batch reports — follow the existing convention). Deviations first,
  then commands, counts, and the exact list of what was verified against the live demo stack.
