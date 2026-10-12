# TASK: P4a — periphery deploy wiring (`PlanExecutor`) + ABI export list

## Context

P3 landed (`70b0bad`): periphery `PlanExecutor` (constructor `(IPoolmigoVault vault_, address owner_)`), vault
`swapExactIn` + capability bits, adapters with `swapExactIn` / `positionState` / ERC-165. P4 wires the deploy
path + ABI exports so the demo stack and the keeper service can use it.

## 1. `script/DemoLocalFork.s.sol`

- Deploy `PlanExecutor(vault, OWNER)` for the **demo vault** during the deploy phase (deployer = anvil #0 =
  OWNER there; pick a spot after `_deployPeriphery`, before the genesis deposits — any clean point).
- Wire it: `vault.setKeeper(planExecutor, true)` **and** `planExecutor.setKeeper(KEEPER, true)` (KEEPER =
  anvil #1, the existing constant).
- Add it to the console2 log block (align style: e.g. `console2.log("plan-executor    :", planExecutor);`).
- Write it to `shared/deployment.local.json` under the EXISTING `periphery` object as `"planExecutor"`
  (same `vm.serializeAddress` pattern as zapIn/zapOut; keep schema v2 and the single `vm.writeJson` call).
  Update the script's doc comment (`periphery` = the two zaps + the plan executor).

## 2. `script/DeployPeriphery.s.sol` (real networks)

- Add a PlanExecutor deploy step after the zaps, following this script's existing ownership-graceful
  conventions (read the header + the zap owner-mismatch branch and mirror them):
  - deploy `new PlanExecutor(vault, owner_)` where `owner_` follows the same OWNER/`--sender` rule the zaps use;
  - if the broadcaster IS the owner-equivalent: also `vault.setKeeper(planExecutor, true)`, and if env
    `PLAN_KEEPER` (optional) is set, `planExecutor.setKeeper(PLAN_KEEPER, true)`;
  - otherwise PRINT the exact calls to run from the owner (same pattern the script already uses for the zaps).
- Update the doc header (env list: `VAULT` required; `PLAN_KEEPER` optional; ownership note) and the closing
  "next:" line (mention the plan executor address + grant the executor a vault-keeper slot + its own keeper).
- Return shape: append to the returned addresses (keep it simple; it currently returns `(zapIn, zapOut)` —
  return `(zapIn, zapOut, planExecutor)` and update callers/tests if anything consumes it — check first;
  if nothing consumes it, a tuple extension is fine).

## 3. `script/export-abis.sh` — three new artifacts

Add, alongside the existing six:
- `src/periphery/PlanExecutor.sol  PlanExecutor  PlanExecutor.json`
- `src/adapters/UniswapV3Adapter.sol  UniswapV3Adapter  UniswapV3Adapter.json`
- `src/adapters/UniswapV4Adapter.sol  UniswapV4Adapter  UniswapV4Adapter.json`

(Why: the keeper service composes plans against PlanExecutor + needs the adapters' planning reads —
`previewAddLiquidity`, `rangeConstraints`, `positionState`.) Keep the script's format (`jq .` of
`forge inspect --json`, 2-space + trailing newline) and its build-info pitfall note.

## 4. Run + verify

- `forge build` clean; then run `script/export-abis.sh` and confirm all NINE files regenerate in
  `shared/abis/` (list them + byte sizes in the report).
- After the export, `forge clean && forge build` again if you run tests post-export (build-info pitfall);
  simplest order: build → tests (non-fork, expect **223/223**) → export script (it may write build-infos —
  that's fine as the LAST step).
- The demo script's correctness is proven by the orchestrator's actual `fork-demo-up.sh` redeploy run
  afterwards — do NOT start anvil or run the fork demo yourself.

## Out of scope

- No contract-source changes; no test-file changes; no FE/BE/`shared/deployment.local.json` content beyond
  what the demo script writes at RUN time (the checked-in file updates during the later redeploy, not now);
  no docs/notes/AGENTS edits. Do not commit. Report: `REPORT-EXECPLAN-P4A.md` (deviations first, commands,
  export list with sizes, suite count).
