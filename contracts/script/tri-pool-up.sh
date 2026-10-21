#!/usr/bin/env bash
# tri-pool-up.sh — the THIRD local demo vault, "tri" (sunTriLP: [USDG, WETH, PONS], 18 real v4 adapters — 6 native on the
# FablesRampETH ETH/USDG pool, 6 hooked on the FablesRamp PONS/USDG pool, 6 native on the Fables ETH/PONS market pool
# (its own per-market hook 0x594e8e62…)), on the LOCAL demo chain (chain id 46630) — either the RUNNING frozen chain or,
# inside script/fork-demo-up.sh (step 6b), the fresh live fork of a rebuild. Never RHC mainnet: every tx is signed with a
# public anvil test key and the chain id must be 46630; RHC itself is only READ (eth_getCode / eth_getStorageAt /
# eth_call, step 2b on a frozen chain). Steps:
#   1. guard: chain id 46630, the "demo" stack is up (registry), anvil #202 (the tri deployer) at nonce 0, gas
#   2. fee-tier restore (frozen chain only): a state frozen without the v3 WETH/PONS fee-10000 reference also lacks the
#      v3 factory's `feeAmountTickSpacing[10000]` slot (never read upstream → 0 = "tier disabled"); write back the RHC
#      value (200 — the canonical v3 tier, read from RHC 2026-10-17) so the real factory can recreate the reference
#  2b. Fables ETH/PONS hook (frozen chain only — a live fork reads it upstream): a state frozen before the tri vault
#      existed never read the hook, so it has no code and the market has no config (`beforeInitialize` reverts
#      `PoolNotConfigured()`). Copy, at ONE pinned RHC block of $FORK_RHC_RPC: its runtime code (anvil_setCode — its
#      immutables, PoolManager / WETH, are in the code), its global slots (0 authority, 7, 0xd pause word) and this
#      market's config (`mapping(PoolId => …)` slots 1 maxFee, 2 pokeFloor, 3 pokeOf, 14 pausedFor, 21 flatFee — the
#      layout found with eth_createAccessList over every view + beforeSwap, 2026-10-17); then every view must answer
#      as on RHC. NOT reproduced: the hook's other markets, the authority's off-chain poke service (a poke copied here
#      expires on its own TTL; the flat 3000 ppm fee does not depend on it), the RHC pool's LP positions and history
#   3. forge clean && forge build (skipped with TRI_SKIP_BUILD=true — fork-demo-up.sh has just built and nothing has
#      compiled since; the OZ plugin needs that single fresh build-info)
#   4. DemoTriPool.s.sol:DemoTriPoolProvision (OWNER #201; idempotent): v3 reference present (or created at the cross
#      price + seeded), Fables ETH/PONS pool live within 100 ticks of the reference (or initialized at its spot +
#      seeded with native ETH + PONS on a frozen chain)
#   5. TWAP: if the reference cannot answer observe(1800) yet (a recreated one has no history), one 1800 s window
#      forward — checked, not remembered, so a rerun after a partial run self-heals
#   6. DemoTriPool.s.sol:DemoTriPool — vault + DepositSplit + 2 executors + 18 adapters (#202), venue / addAdapter /
#      keeper / genesis (#201; K = 10e18 on a ≈ $10 basket), keeper deployTo (#1); appends "tri" to
#      ../shared/deployment.local.json
#   7. spot checks (`check` below)
#   8. DemoTriZap.s.sol:DemoTriZapWire (OWNER #201 = the demo zaps' owner; idempotent): registerVault(tri) on the demo
#      zap-in + zap-out, routes USDG→PONS / PONS→USDG on the v3 fee-10000 PONS reference (600 s / 200 bps / 50 bps —
#      the 1% LP fee needs > 100 bps of the per-leg TWAP haircut; see the script). State on existing contracts only.
# Usage (from contracts/):
#   script/tri-pool-up.sh            # deploy onto the running chain (or the rebuild's live fork)
#   script/tri-pool-up.sh zap        # step 8 only — wire the zaps on a chain whose tri vault is already up
#   script/tri-pool-up.sh check      # spot checks only (fails the run on a broken invariant)
#   script/tri-pool-up.sh reads      # the fidelity reads fork-demo-up.sh diffs across the freeze
# Then: cd ../frontend && pnpm sync:shared. Smoke tests: forge script script/DemoTriSmoke.s.sol, and the USDG-only zap
# e2e forge script script/DemoTriZap.s.sol:DemoTriZapSmoke (see their headers).
# Env: DEMO_ANVIL_PORT (8547) / DEMO_RPC_URL, TRI_SKIP_BUILD (false), TRI_GENESIS_SHARES (10e18, read by the forge
#      script), DEMO_DEPLOYER_KEY (default: the derived #201 key), FORK_RHC_RPC (legacy RHC_RPC; the upstream READ in
#      step 2b — https://rpc.mainnet.chain.robinhood.com; any RHC endpoint, e.g. https://robinhood.drpc.org) and
#      FORK_RHC_HEADER (optional extra HTTP header for it, e.g. "User-Agent: mysun-demo").
set -euo pipefail

PORT="${DEMO_ANVIL_PORT:-${PORT:-8547}}"
RPC="${DEMO_RPC_URL:-http://127.0.0.1:$PORT}"
export PATH="$PATH:$HOME/.foundry/bin"
TEST_MNEMONIC="test test test test test test test test test test test junk"
DEPLOYER_KEY="${DEMO_DEPLOYER_KEY:-$(cast wallet private-key --mnemonic "$TEST_MNEMONIC" --mnemonic-index 201)}"
UPSTREAM="${FORK_RHC_RPC:-${RHC_RPC:-https://rpc.mainnet.chain.robinhood.com}}"
UP_HEADER=()
[ -z "${FORK_RHC_HEADER:-}" ] || UP_HEADER=(--rpc-headers "$FORK_RHC_HEADER")
cd "$(dirname "$0")/.."
DEPLOYMENT=../shared/deployment.local.json

OWNER=0x9B63F0Cef479924E5d2C4E22DBE31E6d0353B448       # #201 — owner / provisioner
TRI_DEPLOYER=0xaAda98978453263132587D0805C4A17376Af9F13 # #202 — every tri CREATE (nonce 0 → deterministic)
KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8       # #1
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
PONS=0x39dBED3a2bd333467115dE45665cC57F813C4571
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
V3_FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
REF_WETH_PONS=0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA # v3 WETH/PONS fee 10000 — the ETH/PONS adapters' reference
FABLES_ETH_PONS=0x594e8e6281eDf2d363a0293a50004Cf868E7a080 # the Fables ETH/PONS market's own hook
POSM=0x58daec3116aae6D93017bAAea7749052E8a04fA7
ETH_POOL_ID=0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551
PONS_POOL_ID=0x486435a1f76cd58193f854c6e6213cd05fd58d637865d02065ff558b387fa6ea
ETH_PONS_POOL_ID=0xb59001413cb070e28433826f927b7265a0813213ba21f454d86896cee3cce674
MAX_GAP=200 # the adapters' spot-vs-TWAP guard (maxSlippageBps, ticks)
ZAP_IN=$(jq -r '.periphery.zapIn' "$DEPLOYMENT")
ZAP_OUT=$(jq -r '.periphery.zapOut' "$DEPLOYMENT")

c() { cast "$@" --rpc-url "$RPC"; }
num() { c "$@" | awk '{print $1}'; }
lc() { tr '[:upper:]' '[:lower:]'; }
up() { cast "$@" --rpc-url "$UPSTREAM" ${UP_HEADER[@]+"${UP_HEADER[@]}"}; } # READ-ONLY upstream (step 2b)

# Vault "tri": [USDG, WETH, PONS], 18 adapters — 6 per pool, each with its own live NFT on its pool, its v4 spot inside
# the deploy guard of its TWAP, a non-zero capability mask, no ETH at rest. Fails the run.
check() {
  local vault n=0 a pid id liq twap spot gap cap native=0 hooked=0 ethpons=0
  vault=$(jq -r '.vaults[] | select(.key=="tri") | .vault' "$DEPLOYMENT")
  [ -n "$vault" ] && [ "$vault" != null ] || { echo "no \"tri\" vault in $DEPLOYMENT" >&2; exit 1; }
  echo "vault [tri]        = $vault  $(c call "$vault" 'symbol()(string)')  tokens $(c call "$vault" 'tokens()(address[])')"
  [ "$(c call "$vault" 'tokens()(address[])' | lc)" = "$(echo "[$USDG, $WETH, $PONS]" | lc)" ] \
    || { echo "tri vault tokens() != [USDG, WETH, PONS]" >&2; exit 1; }
  echo "vault totalTokens  = $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  echo "vault totalSupply  = $(c call "$vault" 'totalSupply()(uint256)')"
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],'); do
    n=$((n + 1))
    pid=$(c call "$a" 'poolId()(bytes32)')
    id=$(num call "$a" 'tokenId()(uint256)')
    liq=$(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id")
    twap=$(num call "$a" 'twapTick()(int24)')
    spot=$(c call "$a" 'spot()(uint160,int24)' | sed -n 2p | awk '{print $1}')
    gap=$((spot > twap ? spot - twap : twap - spot))
    cap=$(num call "$vault" 'adapterCapabilities(address)(uint8)' "$a")
    case "$pid" in
      "$ETH_POOL_ID") native=$((native + 1)) ;;
      "$PONS_POOL_ID") hooked=$((hooked + 1)) ;;
      "$ETH_PONS_POOL_ID") ethpons=$((ethpons + 1)) ;;
      *) echo "tri adapter $a on an unexpected pool $pid" >&2; exit 1 ;;
    esac
    echo "adapter $a  pool ${pid:0:10}  tokenId $id  liquidity $liq  twapTick $twap  v4 spot $spot (gap $gap)  caps $cap"
    echo "  position $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    [ "$id" != 0 ] && [ "$liq" != 0 ] || { echo "tri adapter $a has no live position" >&2; exit 1; }
    [ "$(c call "$POSM" 'ownerOf(uint256)(address)' "$id" | lc)" = "$(echo "$a" | lc)" ] \
      || { echo "tri adapter $a does not own NFT $id" >&2; exit 1; }
    [ "$gap" -le "$MAX_GAP" ] || { echo "tri adapter $a spot/TWAP gap $gap > $MAX_GAP" >&2; exit 1; }
    [ "$cap" != 0 ] || { echo "tri adapter $a has a zero capability mask" >&2; exit 1; }
    [ "$(c balance "$a")" = 0 ] || { echo "tri adapter $a holds ETH" >&2; exit 1; }
  done
  [ "$native/$hooked/$ethpons" = 6/6/6 ] || { echo "tri adapters ETH/USDG / PONS/USDG / ETH/PONS = $native/$hooked/$ethpons, expected 6/6/6" >&2; exit 1; }
  echo "tri vault: 18 adapters (6 native ETH/USDG · 6 hooked PONS/USDG · 6 native ETH/PONS Fables) ✓ · Fables ETH/PONS currentFee $(num call "$FABLES_ETH_PONS" 'currentFee(bytes32,bool)(uint24)' "$ETH_PONS_POOL_ID" true)/$(num call "$FABLES_ETH_PONS" 'currentFee(bytes32,bool)(uint24)' "$ETH_PONS_POOL_ID" false) pips"
}

# The tri reads the demo serves (basket view through all 18 adapters, their guards, the ETH/PONS leg's reference + hook):
# fork-demo-up.sh records them on the live fork and diffs them on the frozen node.
reads() {
  local vault a id
  vault=$(jq -r '.vaults[] | select(.key=="tri") | .vault' "$DEPLOYMENT")
  echo "tri.tokens()        $(c call "$vault" 'tokens()(address[])')"
  echo "tri.totalTokens()   $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  echo "tri.totalSupply()   $(c call "$vault" 'totalSupply()(uint256)')"
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],'); do
    id=$(num call "$a" 'tokenId()(uint256)')
    echo "tri.adapter $a tokenId $id liquidity $(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id") ETH $(c balance "$a")"
    echo "  position() $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    echo "  twapTick() $(c call "$a" 'twapTick()(int24)')  spot() $(c call "$a" 'spot()(uint160,int24)' | tr '\n' ' ')"
  done
  echo "refWethPons.slot0() $(c call "$REF_WETH_PONS" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | tr '\n' ' ')"
  # The zap paths (step 8): the PONS route's 600 s TWAP walk + the vault math, so a zap on the frozen node is cached.
  if [ "$(c call "$ZAP_IN" 'isVaultRegistered(address)(bool)' "$vault")" = true ]; then
    echo "zapIn.previewZap(tri, USDG, 10e6)   $(c call "$ZAP_IN" 'previewZap(address,address,uint256,uint16)(address[],uint256[],uint256,uint256[])' "$vault" "$USDG" 10000000 0 | tr '\n' ' ')"
    echo "zapOut.previewRedeem(tri, USDG, 1e18) $(c call "$ZAP_OUT" 'previewRedeem(address,address,uint256,uint16)(address[],uint256[],uint256,uint256[])' "$vault" "$USDG" 1000000000000000000 0 | tr '\n' ' ')"
  fi
  echo "fablesEthPons.currentFee(ETH->PONS) $(c call "$FABLES_ETH_PONS" 'currentFee(bytes32,bool)(uint24)' "$ETH_PONS_POOL_ID" true)"
  echo "fablesEthPons.currentFee(PONS->ETH) $(c call "$FABLES_ETH_PONS" 'currentFee(bytes32,bool)(uint24)' "$ETH_PONS_POOL_ID" false)"
}

# Step 2b: install the Fables ETH/PONS hook + this market's config from ONE pinned RHC block on a STANDALONE chain (a
# live fork reads them upstream — left alone). Idempotent: a rerun re-copies the same slots (only the config slots are
# written — whatever `beforeInitialize` stored stays). Fails unless every view answers as on RHC.
materialize_fables_hook() {
  local blk code s v n f lv uv up_ts loc_ts exp
  if [ "$(c rpc anvil_nodeInfo | jq -r '.forkConfig.forkUrl // empty')" != "" ]; then
    echo "live fork: the Fables ETH/PONS hook is read upstream (maxFee $(num call "$FABLES_ETH_PONS" 'maxFee(bytes32)(uint24)' "$ETH_PONS_POOL_ID")) — no copy"
    return 0
  fi
  [ "$(up chain-id)" = 4663 ] || { echo "upstream $UPSTREAM is not RHC (chain id $(up chain-id))" >&2; exit 1; }
  blk=$(up block-number)
  up_ts=$(up block "$blk" -f timestamp)
  loc_ts=$(c block latest -f timestamp)
  code=$(up code "$FABLES_ETH_PONS" --block "$blk")
  [ "$code" != 0x ] || { echo "no Fables ETH/PONS hook code on RHC @ $blk" >&2; exit 1; }
  c rpc anvil_setCode "$FABLES_ETH_PONS" "$code" >/dev/null
  for s in 0x0 0x7 0xd; do
    c rpc anvil_setStorageAt "$FABLES_ETH_PONS" "$(cast to-uint256 "$s")" "$(up storage "$FABLES_ETH_PONS" "$s" --block "$blk")" >/dev/null
  done
  for n in 1 2 3 14 21; do
    s=$(cast index bytes32 "$ETH_PONS_POOL_ID" "$n")
    v=$(up storage "$FABLES_ETH_PONS" "$s" --block "$blk")
    if [ "$n" = 3 ]; then
      # pokeOf = (fee0 24 b | fee1 24 b | expiry above): a TIME-bound override. The local clock is not RHC's (a frozen
      # chain can lag by days), so the expiry moves by the clock gap — the poke keeps exactly its RHC remaining TTL
      # (already expired on RHC → already expired here).
      exp=$(cast to-dec "0x${v:2:52}")
      [ "$exp" = 0 ] || { exp=$((exp + loc_ts - up_ts)); [ "$exp" -ge 0 ] || exp=0; }
      v=$(printf '0x%052x%s' "$exp" "${v: -12}")
    fi
    c rpc anvil_setStorageAt "$FABLES_ETH_PONS" "$s" "$v" >/dev/null
    echo "  config slot mapping[$n][pool] = $v"
  done
  echo "  clock gap local − RHC@$blk = $((loc_ts - up_ts)) s (poke expiry shifted by it)"
  for f in 'maxFee(bytes32)' 'pokeFloor(bytes32)' 'flatFee(bytes32)' 'pausedFor(bytes32)' \
    'currentFee(bytes32,bool) true' 'currentFee(bytes32,bool) false'; do
    # shellcheck disable=SC2086 # the optional bool rides in $f
    lv=$(c call "$FABLES_ETH_PONS" ${f%% *} "$ETH_PONS_POOL_ID" $([ "${f#* }" != "$f" ] && echo "${f#* }"))
    # shellcheck disable=SC2086
    uv=$(up call "$FABLES_ETH_PONS" ${f%% *} "$ETH_PONS_POOL_ID" $([ "${f#* }" != "$f" ] && echo "${f#* }") --block "$blk")
    [ "$lv" = "$uv" ] || { echo "Fables hook $f: local $lv != RHC@$blk $uv" >&2; exit 1; }
  done
  for f in 'authority()' 'poolManager()' 'weth()' 'paused()'; do
    [ "$(c call "$FABLES_ETH_PONS" "$f")" = "$(up call "$FABLES_ETH_PONS" "$f" --block "$blk")" ] \
      || { echo "Fables hook $f differs from RHC@$blk" >&2; exit 1; }
  done
  echo "Fables ETH/PONS hook installed from RHC @ $blk ($(( (${#code} - 2) / 2 )) B code): maxFee $(num call "$FABLES_ETH_PONS" 'maxFee(bytes32)(uint24)' "$ETH_PONS_POOL_ID") · currentFee $(num call "$FABLES_ETH_PONS" 'currentFee(bytes32,bool)(uint24)' "$ETH_PONS_POOL_ID" true) pips — views = RHC ✓"
}

# Step 8: the demo zap pair serves "tri" (idempotent — only what differs is written).
wire_zaps() {
  [ "$(c chain-id)" = 46630 ] || { echo "chain id != 46630 — local demo chain only" >&2; exit 1; }
  forge script script/DemoTriZap.s.sol:DemoTriZapWire --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_KEY"
}

case "${1:-up}" in
  check) check; exit 0 ;;
  reads) reads; exit 0 ;;
  zap) wire_zaps; exit 0 ;;
  up) ;;
  *) echo "usage: $0 [up|zap|check|reads]" >&2; exit 1 ;;
esac

echo "== tri 1. guard ($RPC)"
CHAIN_ID=$(c chain-id)
[ "$CHAIN_ID" = 46630 ] || { echo "chain id $CHAIN_ID != 46630 — the tri vault deploys to the LOCAL demo chain only" >&2; exit 1; }
[ "$(cast wallet address --private-key "$DEPLOYER_KEY" | lc)" = "$(echo "$OWNER" | lc)" ] \
  || { echo "deployer key is not anvil #201 ($OWNER)" >&2; exit 1; }
[ "$(c code "$(jq -r '.vaults[] | select(.key=="demo") | .vault' "$DEPLOYMENT")")" != 0x ] \
  || { echo "the \"demo\" stack of $DEPLOYMENT is not on this chain — run script/fork-demo-up.sh" >&2; exit 1; }
TRI_NONCE=$(c nonce "$TRI_DEPLOYER")
[ "$TRI_NONCE" = 0 ] || { echo "tri deployer #202 nonce $TRI_NONCE != 0 — a tri stack is already here (the local norm is redeploy: rebuild the chain)" >&2; exit 1; }
for a in "$OWNER" "$TRI_DEPLOYER" "$KEEPER"; do
  if [ "$(echo "$(c balance "$a" --ether) < 100" | bc)" = 1 ]; then
    c rpc anvil_setBalance "$a" 0x21E19E0C9BAB2400000 >/dev/null # 10,000 ETH (local gas)
  fi
  echo "$a  $(c balance "$a" --ether) ETH"
done

echo "== tri 2. v3 factory fee tier 10000 (frozen-state gap)"
if [ "$(c code "$REF_WETH_PONS")" = 0x ]; then
  TIER_SLOT=$(cast keccak "$(cast abi-encode 'f(uint256,uint256)' 10000 4)") # feeAmountTickSpacing (slot 4)[10000]
  if [ "$(num call "$V3_FACTORY" 'feeAmountTickSpacing(uint24)(int24)' 10000)" = 0 ]; then
    c rpc anvil_setStorageAt "$V3_FACTORY" "$TIER_SLOT" 0x00000000000000000000000000000000000000000000000000000000000000c8 >/dev/null
    echo "restored feeAmountTickSpacing[10000] = $(num call "$V3_FACTORY" 'feeAmountTickSpacing(uint24)(int24)' 10000) (RHC value)"
  fi
  echo "v3 WETH/PONS reference $REF_WETH_PONS absent — DemoTriPoolProvision recreates it"
else
  echo "v3 WETH/PONS reference present (tier $(num call "$V3_FACTORY" 'feeAmountTickSpacing(uint24)(int24)' 10000))"
fi

echo "== tri 2b. Fables ETH/PONS hook (frozen-state gap)"
materialize_fables_hook

echo "== tri 3. build"
if [ "${TRI_SKIP_BUILD:-false}" != true ]; then
  forge clean
  forge build
fi

echo "== tri 4. provision the ETH/PONS venues (OWNER #201)"
forge script script/DemoTriPool.s.sol:DemoTriPoolProvision --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_KEY"

echo "== tri 5. TWAP history of the reference (the adapters observe 1800 s)"
if c call "$REF_WETH_PONS" 'observe(uint32[])(int56[],uint160[])' '[1800,0]' >/dev/null 2>&1; then
  echo "reference observe(1800) answers — no time move"
else
  c rpc evm_increaseTime 1800 >/dev/null
  c rpc evm_mine >/dev/null
  echo "reference history < 1800 s → one window forward: block $(c block-number) · timestamp $(c block latest -f timestamp)"
fi

echo "== tri 6. DemoTriPool.s.sol (CREATEs #202 · owner #201 · keeper #1)"
forge script script/DemoTriPool.s.sol:DemoTriPool --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_KEY"

echo "== tri 7. spot checks"
check

echo "== tri 8. zap wiring (demo zap-in / zap-out → tri, OWNER #201)"
wire_zaps
echo "tri vault is up — next: cd ../frontend && pnpm sync:shared"
