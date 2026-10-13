#!/usr/bin/env bash
# EIP-170 / EIP-3860 size gate for DEPLOYABLE contracts only.
#
# `forge build --sizes` fails the build when ANY artifact exceeds a limit — test harnesses and test-only fixtures
# included (the invariant handlers are far over EIP-170 by design, and `MySunVaultUpgradeExample` /
# `PoolmigoVaultUpgradeExample` inherit the whole vault plus a reinitializer). This gate checks what actually ships:
# every `contract` declared under src/ (abstract contracts, interfaces and libraries excluded), minus the documented
# test-only exemptions below. A new src/ contract is gated by default.
#
# Fails if a gated contract has a negative runtime margin (EIP-170, 24,576 B) or init-code margin (EIP-3860,
# 49,152 B), or is missing from the sizes report (a silent per-file compile failure must not pass the gate).
#
# Usage: script/sizes-gate.sh   (from contracts/, or anywhere; needs forge + jq)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for bin in forge jq; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH"; exit 1; }
done

# Test-only fixtures (upgrade-path proofs, never deployed to a live chain).
EXEMPT=(MySunVaultUpgradeExample PoolmigoVaultUpgradeExample)

# `forge build --sizes` exits non-zero whenever any artifact (tests included) is oversize; the JSON is still complete.
sizes="$(forge build --sizes --json 2>/dev/null || true)"
echo "$sizes" | jq -e 'type == "object" and length > 0' >/dev/null || { echo "ERROR: no sizes report"; exit 1; }

gated=()
while IFS= read -r c; do
  gated+=("$c")
done < <(
  grep -rhoE '^contract [A-Za-z0-9_]+' src | awk '{print $2}' | sort -u |
    grep -vxF -f <(printf '%s\n' "${EXEMPT[@]}")
) # (no mapfile: macOS ships bash 3.2)
[ "${#gated[@]}" -gt 0 ] || { echo "ERROR: no deployable contracts found under src/"; exit 1; }

fail=0
printf '%-30s %10s %10s %10s %10s\n' "contract" "runtime" "margin" "init" "margin"
for c in "${gated[@]}"; do
  row="$(echo "$sizes" | jq -r --arg c "$c" \
    '.[$c] // empty | "\(.runtime_size) \(.runtime_margin) \(.init_size) \(.init_margin)"')"
  if [ -z "$row" ]; then
    echo "FAIL: $c missing from the sizes report (did it compile?)"
    fail=1
    continue
  fi
  read -r rs rm is im <<<"$row"
  printf '%-30s %10s %10s %10s %10s\n' "$c" "$rs" "$rm" "$is" "$im"
  if [ "$rm" -lt 0 ] || [ "$im" -lt 0 ]; then
    echo "FAIL: $c exceeds a size limit (runtime margin $rm B, init-code margin $im B)"
    fail=1
  fi
done
echo "exempt (test-only): ${EXEMPT[*]}"

if [ "$fail" -ne 0 ]; then
  echo "sizes gate: FAILED"
  exit 1
fi
echo "sizes gate: OK (${#gated[@]} deployable contracts within EIP-170 / EIP-3860)"
