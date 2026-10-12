#!/usr/bin/env bash
# fork-demo-up.sh — the local demo stack on Robinhood Chain state, TWO real vaults:
#   "demo" — REAL USDG / WETH: one REAL UniswapV3Adapter (fee-100 pool) + eight REAL UniswapV4NativeEthAdapters on the
#            native ETH/USDG v4 pool behind FablesRampETH (a dedicated native swap executor bridges WETH⇄ETH);
#   "pons" — REAL USDG / PONS: eight REAL UniswapV4HookedAdapters on the FablesRamp-hooked PONS/USDG v4 pool;
# opt-in (env, default OFF, read by DemoLocalFork.s.sol): DEMO_DEPLOY_STOCKS=true adds the mock "stocks" vault,
# DEMO_DEPLOY_V4_HOOKLESS=true adds the hookless UniswapV4Adapter to "demo". Plus the zap periphery (registered to
# the "demo" vault:
# zap-in routes USDG→WETH and zap-out routes WETH→USDG, both on the same fee-100 pool) and the strategy-layer
# PlanExecutor (a vault keeper; keeper #1 is whitelisted on it). One command,
# repeatable, a few minutes.
#
# Why a freeze step: the public RHC RPC is NOT an archive node — it serves state for recent blocks only
# (observed: a fork block aged out after ~10–30 minutes). A live `anvil --fork-url` of it then dies: it
# cannot fetch any uncached slot, and cannot even mine (each block writes a fresh EIP-2935 block-hash slot).
# So the stack is deployed on a fresh live fork, then FROZEN (script/fork-demo-freeze.mjs: every fetched
# account/slot + every local change) and anvil is restarted standalone from that state file — same chain id,
# port, addresses and block height, no upstream dependency, persisted on exit (`anvil --state`). A slot the
# live fork never read would come back as ZERO (e.g. WETH.decimals()), hence the warm-up + fidelity check.
#
# Steps (the upstream-dependent part — 0 to 6 — is kept short and runs first; any failure aborts):
#   0. stop the anvil on $PORT (refuses if the listener is not anvil); start a live fork of RHC, chain id 46630
#   1. guard: chain id 46630 + real RHC contracts present
#   2. warm-up (batched): every upstream read the demo relies on later — token metadata + balances (USDG / WETH /
#      PONS); for the fee-100 pool AND the v3 PONS/USDG fee-10000 reference: state / the newest ~1 h of the
#      observations ring / tick bitmap ±2 words and every initialized tick in them; the PONS/USDG v4 pool's state,
#      bitmap and ticks in the PoolManager (extsload); the FablesRamp hook's per-pool views + its beforeSwap
#   3. gas: every anvil dev account used below gets 10k ETH if it has less than 100
#   4. funding: impersonate the USDG/WETH fee-100 pool (it holds real USDG + WETH), ERC-20-transfer working
#      balances to OWNER (#201), DEMO_USER (#2) and TRADER (#3 — real swap volume in the backend suite); impersonate
#      0x…dEaD (it holds ~320M real PONS) and transfer PONS to the same three + the fee-100 pool (the frontend
#      faucet's source, src/chain/faucet.ts — inert for the v3 pool, which only accounts its own two tokens)
#   5. TWAP: evm_increaseTime 1800 + evm_mine — the adapters guard spot≈TWAP; on a frozen fork one window
#      forward makes the pool's 1800 s TWAP equal its spot (the fork suites' vm.warp)
#   6. guard: the deployer is anvil #201, funded, at nonce 0 on the fork; then forge clean && forge build &&
#      forge script DemoLocalFork.s.sol (anvil #201 key; #1 is the keeper)
#   7. post-deploy spot checks (cast; the "pons" vault's eight adapters are asserted) + the warm-up reads again +
#      the venue + zap preview + "pons" vault / adapter / hook reads (the fidelity baseline — all cached by now)
#   8. freeze: dump local state → stop the fork (flushes foundry's fork cache) → merge → restart standalone;
#      the warm-up reads on the frozen node must equal the baseline byte for byte
#
# Usage (from contracts/):
#   script/fork-demo-up.sh
# The deployer / OWNER is anvil account #201 of Foundry's public test mnemonic (LOCAL ONLY), derived here — NOT
# #0: #0's key is world-known and third parties use it on RHC mainnet, so its nonce at the fork block drifts
# (0x6f3 on 2026-10-05, 0x6fc on 2026-10-08) and with it every CREATE address of the stack. #200 (the previous
# deployer) was rotated out after the 2026-10-10 run saw nonce 89 at fork block 83309800 — any test-mnemonic
# account is public; guard with the nonce check, never with trust. #201 has never sent a transaction on RHC
# (nonce 0): the stack's addresses change only when DemoLocalFork.s.sol does. Step 6 refuses
# to deploy if #201's fork nonce is not 0. (ANVIL_DEV_KEY is no longer read.)
# Env (every default = the shared demo chain):
#   DEMO_ANVIL_PORT  anvil port (8547; legacy alias PORT) — the anvil on it is STOPPED and replaced
#   HOST             anvil bind address (0.0.0.0)
#   DEMO_RPC_URL     RPC the casts / forge scripts use (http://127.0.0.1:$DEMO_ANVIL_PORT)
#   STATE_DIR        working directory (~/.mysun/fork-demo)
#   DEMO_TAG         suffix for every file below ("" → state.json, anvil.log, warm-*.txt, local-dump.json)
#   DEMO_STATE_FILE  frozen state file ($STATE_DIR/state$DEMO_TAG.json)
#   ANVIL_LOG        anvil log ($STATE_DIR/anvil$DEMO_TAG.log)
#   RHC_RPC          upstream (https://rpc.mainnet.chain.robinhood.com)
#   DEMO_DEPLOY_STOCKS / DEMO_DEPLOY_V4_HOOKLESS  opt-in stack sections (false) — passed through to the forge script
#   DEMO_DEPLOYER_KEY  deployer key override (default: the derived #201 key; must still be OWNER below)
# A scratch rehearsal next to the shared chain (never touches :8547 or its files):
#   DEMO_ANVIL_PORT=8548 HOST=127.0.0.1 STATE_DIR=~/.mysun/fork-demo-scratch DEMO_TAG=.pons-scratch \
#     script/fork-demo-up.sh
# (the deploy still writes ../shared/deployment.local.json with rpcUrl http://127.0.0.1:8547 — the shared chain).
# Restart the frozen stack later (no redeploy):
#   anvil --state ~/.mysun/fork-demo/state.json --chain-id 46630 --host 0.0.0.0 --port 8547
#   (scratch: --state $STATE_DIR/state$DEMO_TAG.json --port $DEMO_ANVIL_PORT)
#
# Writes ../shared/deployment.local.json (rpcUrl http://127.0.0.1:8547, "fork": true, "mintable": false,
# "periphery" = the zap-in / zap-out addresses + the PlanExecutor the deploy registered to the "demo" vault).
# Then: cd ../frontend && pnpm sync:shared.
set -euo pipefail

PORT="${DEMO_ANVIL_PORT:-${PORT:-8547}}"
HOST="${HOST:-0.0.0.0}"
RPC="${DEMO_RPC_URL:-http://127.0.0.1:$PORT}"
RHC_RPC="${RHC_RPC:-https://rpc.mainnet.chain.robinhood.com}"
STATE_DIR="${STATE_DIR:-$HOME/.mysun/fork-demo}"
TAG="${DEMO_TAG:-}"
STATE_FILE="${DEMO_STATE_FILE:-$STATE_DIR/state$TAG.json}"
ANVIL_LOG="${ANVIL_LOG:-$STATE_DIR/anvil$TAG.log}"
WARM_PREFORK="$STATE_DIR/warm-prefork$TAG.txt"
WARM_LIVE="$STATE_DIR/warm-live$TAG.txt"
WARM_FROZEN="$STATE_DIR/warm-frozen$TAG.txt"
LOCAL_DUMP="$STATE_DIR/local-dump$TAG.json"
export PATH="$PATH:$HOME/.foundry/bin"
# Anvil #201 of the public test mnemonic — the deployer (see Usage for why not #0/#200). LOCAL ONLY.
TEST_MNEMONIC="test test test test test test test test test test test junk"
DEPLOYER_KEY="${DEMO_DEPLOYER_KEY:-$(cast wallet private-key --mnemonic "$TEST_MNEMONIC" --mnemonic-index 201)}"
cd "$(dirname "$0")/.."
mkdir -p "$STATE_DIR"

# Verified RHC addresses (notes/RHC_ADDRESSES.md).
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
POOL=0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca # v3 USDG/WETH 0.01% — the funding source
NFPM=0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3
POSM=0x58daec3116aae6D93017bAAea7749052E8a04fA7
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951   # v4 PoolManager
UR=0x204FAca1764B154221e35c0d20aBb3c525710498   # UniversalRouter 2.1.2 (official robinhood.json) — adapters' swap router
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3 # canonical Permit2 — UR pulls the user's tokens through it
SR02=0xCaf681a66D020601342297493863E78C959E5cb2 # v3 SwapRouter02 — the backend fee-volume trader trades through it
V3_FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA # v3 factory (for the SwapRouter02 wiring read)
# Vault "pons" (DemoLocalFork.s.sol): real PONS, the FablesRamp-hooked v4 pool, its v3 TWAP reference.
PONS=0x39dBED3a2bd333467115dE45665cC57F813C4571
DEAD=0x000000000000000000000000000000000000dEaD   # holds ~320M real PONS — the PONS funding source
HOOK=0x08E52564Bad99E05a694b4809F397edcA417A080   # FablesRamp (beforeInitialize + beforeSwap)
REF_POOL_PONS=0x7A192E71564ec66eE0763e328a3Ac274942dE4e1 # v3 PONS/USDG fee 10000 — the adapters' TWAP reference
PONS_POOL_ID=0x486435a1f76cd58193f854c6e6213cd05fd58d637865d02065ff558b387fa6ea
PONS_MAX_SLIPPAGE_BPS=200 # the adapters' spot-vs-TWAP guard (DemoLocalFork.s.sol)
# Vault "demo"'s native adapters: the native ETH/USDG v4 pool (currency0 = ETH) behind FablesRampETH.
HOOK_ETH=0x06a889870C8f83640D6816319f72e2aA579b6080
ETH_POOL_ID=0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551
ETH_MAX_SLIPPAGE_BPS=200

# Anvil dev accounts (public, well-known — LOCAL ONLY).
OWNER=0x9B63F0Cef479924E5d2C4E22DBE31E6d0353B448     # #201 deployer / genesis (nonce-stable — see Usage)
KEEPER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8    # #1 keeper
DEMO_USER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC # #2 frontend e2e / demo wallet
TRADER=0x90F79bf6EB2c4f870365E785982E1f101E93b906    # #3 swap volume (backend fee test)

# Working balances: USDG (6 dp) + WETH (18 dp) per account.
FUND=(
  "$OWNER 400000000000 150000000000000000000"    # 400k USDG + 150 WETH
  "$DEMO_USER 250000000000 50000000000000000000" # 250k USDG +  50 WETH
  "$TRADER 1000000000000 100000000000000000000"  #   1M USDG + 100 WETH
)
# Working PONS balances (18 dp; PONS ≈ 0.4 USDG). The fee-100 pool row stocks the frontend faucet.
FUND_PONS=(
  "$OWNER 100000000000000000000000"     # 100k PONS (genesis takes 10k)
  "$DEMO_USER 250000000000000000000000" # 250k PONS
  "$TRADER 1000000000000000000000000"   #   1M PONS
  "$POOL 100000000000000000000000"      # 100k PONS — "Fund my wallet" sends from this address
)

c() { cast "$@" --rpc-url "$RPC"; }
num() { c "$@" | awk '{print $1}'; } # uint call without cast's "[1.3e6]" suffix

# Stop the anvil listening on $PORT (graceful: a fork flushes its cache, a standalone one dumps --state).
stop_anvil() {
  local pid
  pid=$(lsof -nP -t -i "tcp:$PORT" -sTCP:LISTEN 2>/dev/null || true)
  [ -z "$pid" ] && return 0
  if [ "$(basename "$(ps -o comm= -p "$pid")")" != anvil ]; then
    echo "refusing: port $PORT is held by $(ps -o comm= -p "$pid"), not anvil" >&2
    exit 1
  fi
  kill -TERM "$pid"
  for _ in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  echo "anvil $pid did not exit" >&2
  exit 1
}

# Start anvil detached (survives this shell: HUP ignored — macOS nohup refuses without a console).
start_anvil() {
  (zsh -c 'trap "" HUP; exec "$@"' anvil "$(command -v anvil)" "$@" --chain-id 46630 --host "$HOST" --port "$PORT" \
    </dev/null >>"$ANVIL_LOG" 2>&1 &)
  for _ in $(seq 1 60); do c chain-id >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "anvil did not come up — see $ANVIL_LOG" >&2
  exit 1
}

echo "== 0. fresh live fork of RHC on :$PORT (log $ANVIL_LOG)"
stop_anvil
# Pin the fork block explicitly (auto-latest round-robins over RHC's public backends, which have wildly
# diverged — a fork landed ~2.1M blocks behind on 2026-10-10/11, and anvil_nodeInfo reports
# forkBlockNumber=null for unpinned forks, which breaks the freeze cache lookup). Refuse to fork a stale
# backend (>2 h behind wall clock — the demo's whole point is to mirror current mainnet). Probe up to
# 3 times: the public RPC alternates between healthy and lagging backends.
FORK_BLOCK=""
for _ in 1 2 3; do
  # cast directly (NOT the `c` helper — it embeds --rpc-url "$RPC"; a second --rpc-url is a fatal duplicate flag)
  FORK_BLOCK=$(cast block-number --rpc-url "$RHC_RPC" 2>/dev/null)
  FORK_TS=$(cast block latest -f timestamp --rpc-url "$RHC_RPC" 2>/dev/null)
  NOW=$(date +%s)
  [ -n "$FORK_BLOCK" ] && [ $((NOW - FORK_TS)) -lt 7200 ] && break
  echo "upstream probe: block $FORK_BLOCK · timestamp $FORK_TS vs now $NOW — stale, retrying…" >&2
  sleep 3
done
[ $((NOW - ${FORK_TS:-0})) -lt 7200 ] || {
  echo "upstream RPC is stale (>2 h behind) after 3 probes — refusing to fork (retry later)" >&2
  exit 1
}
echo "upstream RHC latest: block $FORK_BLOCK · timestamp $FORK_TS (fresh ✓)"
start_anvil --fork-url "$RHC_RPC" --fork-block-number "$FORK_BLOCK"
FORK_BLOCK=${FORK_BLOCK:-$(c rpc anvil_nodeInfo | jq -r '.forkConfig.forkBlockNumber')}
echo "forked RHC at block $FORK_BLOCK"

echo "== 1. guard"
CHAIN_ID=$(c chain-id)
[ "$CHAIN_ID" = 46630 ] || { echo "chain id $CHAIN_ID != 46630" >&2; exit 1; }
[ "$(c code "$USDG")" != 0x ] || { echo "no code at USDG — $RPC is not an RHC fork" >&2; exit 1; }
echo "chain id $CHAIN_ID · block $(c block-number) · USDG symbol $(c call "$USDG" 'symbol()(string)')"
# The adapters swap through UR 2.1.2: it must be the RHC-wired router (a mainnet-wired copy answers with the
# mainnet PoolManager). Reading it also pulls its code into the fork cache, so the frozen state keeps it.
UR_PM=$(c call "$UR" 'poolManager()(address)' | tr '[:upper:]' '[:lower:]')
[ "$UR_PM" = "$(echo "$PM" | tr '[:upper:]' '[:lower:]')" ] || { echo "UniversalRouter $UR is not wired to the RHC PoolManager ($UR_PM)" >&2; exit 1; }
echo "UniversalRouter $UR · poolManager $UR_PM"
# The backend fee test (c2) still trades as an ordinary participant through the v3 SwapRouter02 — on the
# FROZEN node its code must exist, so pull it into the cache here too (the OLD adapter's constructor used
# to read it; nothing in the new deploy touches it). The factory read doubles as its wiring check.
SR02_FACTORY=$(c call "$SR02" 'factory()(address)' | tr '[:upper:]' '[:lower:]')
[ "$SR02_FACTORY" = "$(echo "$V3_FACTORY" | tr '[:upper:]' '[:lower:]')" ] || { echo "SwapRouter02 $SR02 factory != RHC v3 factory ($SR02_FACTORY)" >&2; exit 1; }
echo "SwapRouter02 $SR02 · factory $SR02_FACTORY"

echo "== 2. warm-up: the upstream reads the demo relies on (live fork → fork cache)"
WARM=$(node script/fork-demo-freeze.mjs warm "$RPC" "$WARM_PREFORK")
echo "$WARM" | grep -v '^CENTER_TICK='
CENTER_TICK=$(echo "$WARM" | sed -n 's/^CENTER_TICK=//p')

echo "== 3. gas (ETH) for the dev accounts"
for a in "$OWNER" "$KEEPER" "$DEMO_USER" "$TRADER"; do
  bal=$(c balance "$a" --ether)
  if [ "$(echo "$bal < 100" | bc)" = 1 ]; then
    c rpc anvil_setBalance "$a" 0x21E19E0C9BAB2400000 >/dev/null # 10,000 ETH
    bal=$(c balance "$a" --ether)
  fi
  echo "$a  $bal ETH"
done

echo "== 4. funding: impersonate the fee-100 pool → real USDG / WETH"
c rpc anvil_impersonateAccount "$POOL" >/dev/null
c rpc anvil_setBalance "$POOL" 0xDE0B6B3A7640000 >/dev/null # 1 ETH for gas
for row in "${FUND[@]}"; do
  read -r to usdg weth <<<"$row"
  c send --unlocked --from "$POOL" "$USDG" 'transfer(address,uint256)' "$to" "$usdg" >/dev/null
  c send --unlocked --from "$POOL" "$WETH" 'transfer(address,uint256)' "$to" "$weth" >/dev/null
  echo "$to  USDG $(num call "$USDG" 'balanceOf(address)(uint256)' "$to")  WETH $(num call "$WETH" 'balanceOf(address)(uint256)' "$to")"
done
c rpc anvil_stopImpersonatingAccount "$POOL" >/dev/null
echo "pool left with USDG $(num call "$USDG" 'balanceOf(address)(uint256)' "$POOL")  WETH $(num call "$WETH" 'balanceOf(address)(uint256)' "$POOL")"

echo "== 4b. funding: impersonate 0x…dEaD → real PONS (exact-delta checked)"
c rpc anvil_impersonateAccount "$DEAD" >/dev/null
c rpc anvil_setBalance "$DEAD" 0xDE0B6B3A7640000 >/dev/null # 1 ETH for gas
for row in "${FUND_PONS[@]}"; do
  read -r to pons <<<"$row"
  before=$(num call "$PONS" 'balanceOf(address)(uint256)' "$to")
  c send --unlocked --from "$DEAD" "$PONS" 'transfer(address,uint256)' "$to" "$pons" >/dev/null
  after=$(num call "$PONS" 'balanceOf(address)(uint256)' "$to")
  [ "$(echo "$after - $before" | bc)" = "$pons" ] || { echo "PONS transfer to $to: delta $(echo "$after - $before" | bc) != $pons" >&2; exit 1; }
  echo "$to  PONS $after"
done
c rpc anvil_stopImpersonatingAccount "$DEAD" >/dev/null
echo "0x…dEaD left with PONS $(num call "$PONS" 'balanceOf(address)(uint256)' "$DEAD")"

echo "== 5. TWAP: one 1800 s window forward"
c rpc evm_increaseTime 1800 >/dev/null
c rpc evm_mine >/dev/null
echo "block $(c block-number) · timestamp $(c block latest -f timestamp)"

echo "== 6. deployer guard + clean build + DemoLocalFork.s.sol"
# The deployer must be anvil #201 (= DemoLocalFork.s.sol's OWNER), funded, and unused on RHC (fork nonce 0) —
# otherwise every address of the stack would shift. Fail loudly rather than deploy a drifted stack.
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
[ "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" = "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" ] \
  || { echo "deployer key is $DEPLOYER, expected anvil #201 $OWNER" >&2; exit 1; }
DEPLOYER_NONCE=$(c nonce "$OWNER")
DEPLOYER_ETH=$(c balance "$OWNER" --ether)
echo "deployer $DEPLOYER (anvil #201) · nonce $DEPLOYER_NONCE · $DEPLOYER_ETH ETH · USDG $(num call "$USDG" 'balanceOf(address)(uint256)' "$OWNER") · WETH $(num call "$WETH" 'balanceOf(address)(uint256)' "$OWNER") · PONS $(num call "$PONS" 'balanceOf(address)(uint256)' "$OWNER")"
[ "$DEPLOYER_NONCE" = 0 ] || { echo "deployer nonce $DEPLOYER_NONCE != 0 on the fork — #201 was used on RHC; addresses would drift" >&2; exit 1; }
[ "$(echo "$DEPLOYER_ETH >= 100" | bc)" = 1 ] || { echo "deployer has only $DEPLOYER_ETH ETH" >&2; exit 1; }
forge clean
forge build
forge script script/DemoLocalFork.s.sol --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_KEY"

check() {
  local deployment=../shared/deployment.local.json vault v3 v4 zap_in zap_out plan_executor
  vault=$(jq -r '.vaults[] | select(.key=="demo") | .vault' "$deployment")
  zap_in=$(jq -r '.periphery.zapIn' "$deployment")
  zap_out=$(jq -r '.periphery.zapOut' "$deployment")
  plan_executor=$(jq -r '.periphery.planExecutor' "$deployment")
  echo "deployment.local.json: fork=$(jq '.fork' "$deployment") mintable=$(jq '.mintable' "$deployment") rpcUrl=$(jq -r '.rpcUrl' "$deployment")"
  echo "chain id $(c chain-id) · block $(c block-number)"
  echo "USDG.symbol()      = $(c call "$USDG" 'symbol()(string)')"
  echo "vault [demo]       = $vault  $(c call "$vault" 'symbol()(string)')"
  echo "vault totalTokens  = $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  check_demo_adapters "$vault"
  echo "zap-in             = $zap_in  vault registered $(c call "$zap_in" 'isVaultRegistered(address)(bool)' "$vault")"
  echo "zap-out            = $zap_out  vault registered $(c call "$zap_out" 'isVaultRegistered(address)(bool)' "$vault")"
  echo "plan-executor      = $plan_executor  vault keeper $(c call "$vault" 'isKeeper(address)(bool)' "$plan_executor")  keeper(#1) $(c call "$plan_executor" 'isKeeper(address)(bool)' "$KEEPER")  nonce(#1) $(num call "$plan_executor" 'nonces(address)(uint256)' "$KEEPER")"
  check_pons
}

# Vault "demo": [USDG, WETH]; adapters()[0] = the v3 adapter (NFT in the v3 NFPM), the rest v4 — the eight natives on
# the FablesRampETH pool (poolId $ETH_POOL_ID; + the hookless one if DEMO_DEPLOY_V4_HOOKLESS). Each native: one live NFT,
# no ETH at rest, v4 spot inside the deploy guard of its TWAP (the v3 fee-100 reference). Fails the run.
check_demo_adapters() {
  local vault=$1 v3 n=0 natives=0 a pid id liq twap spot gap ref_tick
  local adapters=($(c call "$vault" 'adapters()(address[])' | tr -d '[],'))
  ref_tick=$(c call "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | sed -n 2p | awk '{print $1}')
  v3=${adapters[0]}
  echo "adapter $v3 (v3)  tokenId $(num call "$v3" 'tokenId()(uint256)')  twapTick $(num call "$v3" 'twapTick()(int24)') (fee-100 spot $ref_tick)"
  echo "  position $(c call "$v3" 'position()(address[],uint256[])' | tr '\n' ' ')"
  [ "$(num call "$NFPM" 'balanceOf(address)(uint256)' "$v3")" = 1 ] || { echo "v3 adapter $v3 NFT count != 1" >&2; exit 1; }
  [ "$(c call "$NFPM" 'ownerOf(uint256)(address)' "$(num call "$v3" 'tokenId()(uint256)')" | tr '[:upper:]' '[:lower:]')" = "$(echo "$v3" | tr '[:upper:]' '[:lower:]')" ] \
    || { echo "v3 adapter $v3 does not own its NFT" >&2; exit 1; }
  for a in "${adapters[@]:1}"; do
    n=$((n + 1))
    pid=$(c call "$a" 'poolId()(bytes32)')
    id=$(num call "$a" 'tokenId()(uint256)')
    liq=$(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id")
    twap=$(num call "$a" 'twapTick()(int24)')
    spot=$(c call "$a" 'spot()(uint160,int24)' | sed -n 2p | awk '{print $1}')
    gap=$((spot > twap ? spot - twap : twap - spot))
    echo "adapter $a (v4 $([ "$pid" = "$ETH_POOL_ID" ] && echo native || echo other))  tokenId $id  liquidity $liq  twapTick $twap  v4 spot $spot (gap $gap)  ETH $(c balance "$a")"
    echo "  position $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    [ "$id" != 0 ] && [ "$liq" != 0 ] || { echo "demo adapter $a has no live position" >&2; exit 1; }
    [ "$(c call "$POSM" 'ownerOf(uint256)(address)' "$id" | tr '[:upper:]' '[:lower:]')" = "$(echo "$a" | tr '[:upper:]' '[:lower:]')" ] \
      || { echo "demo adapter $a does not own NFT $id" >&2; exit 1; }
    [ "$gap" -le "$ETH_MAX_SLIPPAGE_BPS" ] || { echo "demo adapter $a spot/TWAP gap $gap > $ETH_MAX_SLIPPAGE_BPS" >&2; exit 1; }
    if [ "$pid" = "$ETH_POOL_ID" ]; then
      natives=$((natives + 1))
      [ "$(c balance "$a")" = 0 ] || { echo "native adapter $a holds ETH" >&2; exit 1; }
    fi
  done
  [ "$natives" = 8 ] || { echo "demo vault has $natives native adapters, expected 8" >&2; exit 1; }
  echo "demo vault: 1 v3 + $n v4 adapters ($natives native on the FablesRampETH pool) · hookEth currentFee ETH->USDG $(num call "$HOOK_ETH" 'currentFee(bytes32,bool)(uint24)' "$ETH_POOL_ID" true)  USDG->ETH $(num call "$HOOK_ETH" 'currentFee(bytes32,bool)(uint24)' "$ETH_POOL_ID" false) (pips)"
}

# Vault "pons": [USDG, PONS], eight hooked adapters — each with a live NFT on the hooked pool, its TWAP on the
# reference spot (no reference trade inside the window) and its v4 spot inside the deploy guard. Fails the run.
check_pons() {
  local deployment=../shared/deployment.local.json vault ref_tick n=0 a id liq twap spot gap
  vault=$(jq -r '.vaults[] | select(.key=="pons") | .vault' "$deployment")
  echo "vault [pons]       = $vault  $(c call "$vault" 'symbol()(string)')  tokens $(c call "$vault" 'tokens()(address[])')"
  [ "$(c call "$vault" 'tokens()(address[])' | tr '[:upper:]' '[:lower:]')" = "$(echo "[$USDG, $PONS]" | tr '[:upper:]' '[:lower:]')" ] \
    || { echo "pons vault tokens() != [USDG, PONS]" >&2; exit 1; }
  echo "vault totalTokens  = $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  ref_tick=$(c call "$REF_POOL_PONS" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | sed -n 2p | awk '{print $1}')
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],'); do
    n=$((n + 1))
    id=$(num call "$a" 'tokenId()(uint256)')
    liq=$(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id")
    twap=$(num call "$a" 'twapTick()(int24)')
    spot=$(c call "$a" 'spot()(uint160,int24)' | sed -n 2p | awk '{print $1}')
    gap=$((spot > twap ? spot - twap : twap - spot))
    echo "adapter $a  tokenId $id  liquidity $liq  twapTick $twap (ref spot $ref_tick)  v4 spot $spot (gap $gap)"
    echo "  position $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    [ "$id" != 0 ] && [ "$liq" != 0 ] || { echo "pons adapter $a has no live position" >&2; exit 1; }
    [ "$(c call "$POSM" 'ownerOf(uint256)(address)' "$id" | tr '[:upper:]' '[:lower:]')" = "$(echo "$a" | tr '[:upper:]' '[:lower:]')" ] \
      || { echo "pons adapter $a does not own NFT $id" >&2; exit 1; }
    [ "$twap" = "$ref_tick" ] || { echo "pons adapter $a twapTick $twap != reference spot $ref_tick" >&2; exit 1; }
    [ "$gap" -le "$PONS_MAX_SLIPPAGE_BPS" ] || { echo "pons adapter $a spot/TWAP gap $gap > $PONS_MAX_SLIPPAGE_BPS" >&2; exit 1; }
  done
  [ "$n" = 8 ] || { echo "pons vault has $n adapters, expected 8" >&2; exit 1; }
  echo "hook currentFee    = PONS->USDG $(num call "$HOOK" 'currentFee(bytes32,bool)(uint24)' "$PONS_POOL_ID" true)  USDG->PONS $(num call "$HOOK" 'currentFee(bytes32,bool)(uint24)' "$PONS_POOL_ID" false) (pips)"
}

# The venue reads the post-freeze paths depend on (a zap swap walks UR → Permit2 → pool; v4 withdrawals walk
# POSM → PM). Each call also fetches the contract's code into the fork cache; appended to the warm baseline,
# so the frozen node must answer them identically too.
venue_reads() {
  echo "UR.poolManager()           $(c call "$UR" 'poolManager()(address)')"
  echo "Permit2.DOMAIN_SEPARATOR() $(c call "$PERMIT2" 'DOMAIN_SEPARATOR()(bytes32)')"
  echo "NFPM.factory()             $(c call "$NFPM" 'factory()(address)')"
  echo "POSM.nextTokenId()         $(c call "$POSM" 'nextTokenId()(uint256)' | awk '{print $1}')"
  echo "PM.owner()                 $(c call "$PM" 'owner()(address)')"
  echo "SR02.factory()             $(c call "$SR02" 'factory()(address)')"
}

# The zap preview reads: they exercise each zap's own path (vault math, the typed route, the pool's 600 s
# TWAP walk) while the fork is live, so a user's zap on the frozen node takes the cached path.
zap_reads() {
  local deployment=../shared/deployment.local.json vault zap_in zap_out
  vault=$(jq -r '.vaults[] | select(.key=="demo") | .vault' "$deployment")
  zap_in=$(jq -r '.periphery.zapIn' "$deployment")
  zap_out=$(jq -r '.periphery.zapOut' "$deployment")
  echo "zapIn.isVaultRegistered(demo)      $(c call "$zap_in" 'isVaultRegistered(address)(bool)' "$vault")"
  echo "zapIn.previewZap(demo, USDG, 1000e6) $(c call "$zap_in" 'previewZap(address,address,uint256,uint16)(address[],uint256[],uint256,uint256[])' "$vault" "$USDG" 1000000000 0 | tr '\n' ' ')"
  echo "zapOut.isVaultRegistered(demo)     $(c call "$zap_out" 'isVaultRegistered(address)(bool)' "$vault")"
  echo "zapOut.previewRedeem(demo, USDG, 1000e18) $(c call "$zap_out" 'previewRedeem(address,address,uint256,uint16)(address[],uint256[],uint256,uint256[])' "$vault" "$USDG" 1000000000000000000000 0 | tr '\n' ' ')"
}

# Vault "pons" reads the demo serves (the vault's basket view through all eight adapters, each adapter's guards, the
# hook's fee resolution): baseline on the live fork, re-read on the frozen node.
pons_reads() {
  local deployment=../shared/deployment.local.json vault a id
  vault=$(jq -r '.vaults[] | select(.key=="pons") | .vault' "$deployment")
  echo "pons.tokens()        $(c call "$vault" 'tokens()(address[])')"
  echo "pons.totalTokens()   $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  echo "pons.totalSupply()   $(c call "$vault" 'totalSupply()(uint256)')"
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],'); do
    id=$(num call "$a" 'tokenId()(uint256)')
    echo "pons.adapter $a tokenId $id liquidity $(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id")"
    echo "  position() $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    echo "  twapTick() $(c call "$a" 'twapTick()(int24)')  spot() $(c call "$a" 'spot()(uint160,int24)' | tr '\n' ' ')"
  done
  echo "hook.currentFee(pons, PONS->USDG) $(c call "$HOOK" 'currentFee(bytes32,bool)(uint24)' "$PONS_POOL_ID" true)"
  echo "hook.currentFee(pons, USDG->PONS) $(c call "$HOOK" 'currentFee(bytes32,bool)(uint24)' "$PONS_POOL_ID" false)"
}

# Vault "demo" reads the demo serves: the basket view through all its adapters, each adapter's guards and NFT, the
# native executor's (zero) balances and FablesRampETH's fee resolution — baseline on the live fork, re-read frozen.
eth_reads() {
  local deployment=../shared/deployment.local.json vault a id
  vault=$(jq -r '.vaults[] | select(.key=="demo") | .vault' "$deployment")
  echo "demo.totalTokens()   $(c call "$vault" 'totalTokens()(address[],uint256[])' | tr '\n' ' ')"
  echo "demo.totalSupply()   $(c call "$vault" 'totalSupply()(uint256)')"
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],'); do
    id=$(num call "$a" 'tokenId()(uint256)')
    echo "demo.adapter $a tokenId $id ETH $(c balance "$a")"
    echo "  position() $(c call "$a" 'position()(address[],uint256[])' | tr '\n' ' ')"
    echo "  twapTick() $(c call "$a" 'twapTick()(int24)')"
  done
  for a in $(c call "$vault" 'adapters()(address[])' | tr -d '[],' | cut -d' ' -f2-); do
    id=$(num call "$a" 'tokenId()(uint256)')
    echo "demo.v4 $a liquidity $(num call "$POSM" 'getPositionLiquidity(uint256)(uint128)' "$id")  spot() $(c call "$a" 'spot()(uint160,int24)' | tr '\n' ' ')  poolId $(c call "$a" 'poolId()(bytes32)')"
  done
  echo "hookEth.currentFee(eth, ETH->USDG) $(c call "$HOOK_ETH" 'currentFee(bytes32,bool)(uint24)' "$ETH_POOL_ID" true)"
  echo "hookEth.currentFee(eth, USDG->ETH) $(c call "$HOOK_ETH" 'currentFee(bytes32,bool)(uint24)' "$ETH_POOL_ID" false)"
}

echo "== 7. post-deploy spot checks (live fork) + fidelity baseline"
check
node script/fork-demo-freeze.mjs warm "$RPC" "$WARM_LIVE" "$CENTER_TICK" | grep -v '^CENTER_TICK='
{ venue_reads; zap_reads; eth_reads; pons_reads; } | tee -a "$WARM_LIVE"

echo "== 8. freeze: live fork → standalone anvil state ($STATE_FILE)"
node script/fork-demo-freeze.mjs dump "$RPC" "$LOCAL_DUMP"
stop_anvil # the fork flushes ~/.foundry/cache/rpc/<chain>/$FORK_BLOCK on exit
node script/fork-demo-freeze.mjs merge "$LOCAL_DUMP" "$FORK_BLOCK" "$STATE_FILE"
start_anvil --state "$STATE_FILE"
node script/fork-demo-freeze.mjs warm "$RPC" "$WARM_FROZEN" "$CENTER_TICK" | grep -v '^CENTER_TICK='
{ venue_reads; zap_reads; eth_reads; pons_reads; } | tee -a "$WARM_FROZEN"
if ! diff -u "$WARM_LIVE" "$WARM_FROZEN"; then
  echo "freeze fidelity FAILED: the frozen node answers the warm-up reads differently (diff above)" >&2
  exit 1
fi
echo "freeze fidelity: all $(wc -l <"$WARM_FROZEN" | tr -d ' ') warm-up reads answer identically on the frozen node"
c rpc evm_mine >/dev/null # proves the standalone node mines (the aged-out live fork could not)
echo "-- spot checks (frozen standalone anvil) --"
check
echo "fork demo stack is up on :$PORT — next: cd ../frontend && pnpm sync:shared"
