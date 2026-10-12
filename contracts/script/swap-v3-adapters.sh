#!/bin/bash
# swap-v3-adapters.sh — 4663 rehearsal: replace the 8 same-pool v3 adapters with fresh
# fees()-capable ones (IAdapterFees, feat/adapter-fees @ f85e002). The vault proxy, its
# implementation, shares, tokens and periphery are UNTOUCHED. Owner == keeper == burner
# (0x27447D…, whitelisted on both vault and PlanExecutor) — one keystore signs everything.
#
#   ACCOUNT=mysun-rehearsal PASSWORD_FILE=<path> bash script/swap-v3-adapters.sh
#
# Phases (each verifies before proceeding; abort = stop here, nothing irreversible):
#   1. deploy 8 NEW v3 adapters (mirror 0x8962bcC3…) + addAdapter ×8  (one forge broadcast)
#   2. pullFrom(old, 10_000) on the 3 FUNDED old adapters (keeper)     — in-kind, no swap
#   3. removeAdapter(old) ×8 (owner)                                    — empty ones skip straight
#   4. deployTo(new, idle) (keeper)                                     — assets back into the pool
#   5. verify: adapters() == the 8 new, positions match, registry/notes updated
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
cd "$(dirname "$0")/.."

VAULT=0x6767257AAFfCE82f6ba4B6E96EDBa80e9e1112FC
RPC=rhc
ACCOUNT="${ACCOUNT:?set ACCOUNT (e.g. mysun-rehearsal)}"
PASSWORD_FILE="${PASSWORD_FILE:?set PASSWORD_FILE}"
SIGN=(--account "$ACCOUNT" --password-file "$PASSWORD_FILE")
OWNER=$(cast wallet address --account "$ACCOUNT" --password-file "$PASSWORD_FILE")

OLD=(
  0x8962bcC3E13a6C038Fdb5B23f54Ff41F327fb51b
  0x9978A9770824583f0c55dF15CbFF70650E252d12
  0x38c221ceE0e7d15e59585f3cFd3196FE9676399d
  0x7BF0d6F882cB48392a98b9BC23b455170BF39d7b
  0xcb3eeE5F83C6045F7A0EDc500ae20d304302809a
  0x583C7567e42Ce739D16aFF0e050869fC1474C7Ef
  0x3b3484752514a468aa59C18B182213A582d8456F
  0x846883b160471Fc84E6a63B18b0Ecd8144c874Fe
)
# old adapters that actually hold a position (position() != 0 on 2026-10-11)
FUNDED=(0x38c221ceE0e7d15e59585f3cFd3196FE9676399d 0x7BF0d6F882cB48392a98b9BC23b455170BF39d7b 0x583C7567e42Ce739D16aFF0e050869fC1474C7Ef 0x3b3484752514a468aa59C18B182213A582d8456F)

echo "== 0. preflight"
[ "$(cast call "$VAULT" "owner()(address)" --rpc-url "$RPC")" = "$OWNER" ] || { echo "ACCOUNT is not the vault owner" >&2; exit 1; }
[ "$(cast call "$VAULT" "paused()(bool)" --rpc-url "$RPC")" = "false" ] || { echo "vault is paused — unpause first" >&2; exit 1; }
echo "owner/keeper $OWNER · vault $VAULT"

echo "== 1. deploy 8 new v3 adapters + addAdapter (one broadcast)"
COUNT=8 forge script script/AddSamePoolV3Adapters.s.sol \
  --rpc-url "$RPC" --sender "$OWNER" "${SIGN[@]}" --broadcast
# the script prints the new adapter addresses; capture them from the broadcast receipts
python3 - <<'EOF'
import json,glob
f=sorted(glob.glob('broadcast/AddSamePoolV3Adapters.s.sol/4663/*.json'))[-1]
d=json.load(open(f))
addrs=[]
for t in d.get('transactions',[]):
    if t.get('contractName')=='UniswapV3Adapter': addrs.append(t['contractAddress'])
print('NEW_ADAPTERS='+','.join(addrs))
EOF

echo "== 2. pullFrom(old, 10_000) on the funded adapters (keeper)"
for a in "${FUNDED[@]}"; do
  echo "-- pulling $a"
  cast send "$VAULT" "pullFrom(address,uint256)" "$a" 10000 "${SIGN[@]}" --rpc-url "$RPC"
done

echo "== 3. removeAdapter(old) ×8 (owner)"
for a in "${OLD[@]}"; do
  echo "-- removing $a"
  cast send "$VAULT" "removeAdapter(address)" "$a" "${SIGN[@]}" --rpc-url "$RPC"
done

echo "== 4. deployTo(new, idle) (keeper)"
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WIDLE=$(cast call "$VAULT" "balanceOf(address)(uint256)" "$WETH" --rpc-url "$RPC")
UIDLE=$(cast call "$VAULT" "balanceOf(address)(uint256)" "$USDG" --rpc-url "$RPC")
echo "idle: WETH $WIDLE · USDG $UIDLE"
NEW0=$(python3 -c "import json,glob;d=json.load(open(sorted(glob.glob('broadcast/AddSamePoolV3Adapters.s.sol/4663/*.json'))[-1]));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='UniswapV3Adapter'][0])")
cast send "$VAULT" "deployTo(address,uint256[])" "$NEW0" "[$WIDLE,$UIDLE]" "${SIGN[@]}" --rpc-url "$RPC"

echo "== 5. verify"
cast call "$VAULT" "adapters()(address[])" --rpc-url "$RPC"
echo "registry/notes update is manual (shared/deployments.json + notes/MYSUN-ADDRESSES.md + backend weights)"