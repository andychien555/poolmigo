#!/usr/bin/env bash
# export-abis.sh — regenerate shared/abis/*.json from the compiled contracts.
#
# shared/abis is the monorepo's single source of truth for ABIs: the frontend consumes it via
# `pnpm sync:shared` (scripts/sync-shared.ts) and the backend via `pnpm run sync-abis`
# (scripts/sync-abis.mjs). Rerun this whenever an ABI changes (functions / errors / events),
# then regenerate both consumers.
#
# Format: `jq .` of `forge inspect --json` (2-space indent + trailing newline) — re-running on
# unchanged contracts is diff-clean.
#
# NOTE (OpenZeppelin upgrades plugin pitfall): `forge inspect` writes its own build-info files. If a
# deploy/upgrade script or a fork suite runs afterwards, do `forge clean && forge build` first —
# otherwise the plugin can fail with 'Found multiple contracts' / '... does not contain storage layout'.
#
# Usage: contracts/script/export-abis.sh   (requires forge + jq on PATH; run from anywhere)
set -euo pipefail
cd "$(dirname "$0")/.." # -> contracts/

export_abi() {
  local src="$1" contract="$2" out="../shared/abis/$3"
  forge inspect "$src:$contract" abi --json | jq . > "$out"
  echo "wrote $out ($(jq length "$out") entries)"
}

export_abi src/PoolmigoVaultUpgradeable.sol  PoolmigoVaultUpgradeable  PoolmigoVaultUpgradeable.json
export_abi src/interfaces/IPositionAdapter.sol IPositionAdapter        IPositionAdapter.json
export_abi test/mocks/MockToken.sol          MockToken                 MockToken.json
export_abi test/mocks/MockPositionAdapter.sol MockPositionAdapter      MockPositionAdapter.json
export_abi src/periphery/PoolmigoZapIn.sol   PoolmigoZapIn   PoolmigoZapIn.json
export_abi src/periphery/PoolmigoZapOut.sol  PoolmigoZapOut  PoolmigoZapOut.json
export_abi src/periphery/PlanExecutor.sol    PlanExecutor    PlanExecutor.json
export_abi src/adapters/UniswapV3Adapter.sol UniswapV3Adapter UniswapV3Adapter.json
export_abi src/adapters/UniswapV4Adapter.sol UniswapV4Adapter UniswapV4Adapter.json
