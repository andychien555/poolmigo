#!/usr/bin/env node
/**
 * fork-demo-freeze.mjs — turn the live RHC-fork anvil into a STANDALONE anvil state file.
 *
 * Why: the public RHC RPC is not an archive node — it serves state for recent blocks only (observed: ~10–30 minutes).
 * Once the fork block ages out, anvil can no longer fetch anything it has not already cached, and even
 * mining a block fails (every block writes a fresh EIP-2935 block-hash slot, whose original value must be
 * fetched upstream: "historical state … is not available"). A long-running LAN demo therefore cannot stay
 * a live fork. Instead, right after the stack is deployed on the fork, its state is frozen:
 *
 *   state = (every account + storage slot anvil FETCHED from RHC — foundry's fork cache, flushed on exit)
 *         ⊕ (everything changed LOCALLY — `anvil_dumpState`: the deployed stack, balances, blocks, txs)
 *
 * and anvil is restarted from it with `--state` (no --fork-url). Slots never fetched read as zero — fine
 * for the demo (a never-touched slot of a contract the stack never read), but NOT a full chain copy.
 *
 * The fork cache only holds what the fork actually READ, so everything the demo reads later must be read
 * while the fork is still live — `warm` does that (batched: the RPC's state window can be ~10 minutes), and
 * the same reads re-run on the frozen node must answer identically (fork-demo-up.sh diffs them).
 *
 * Subcommands (fork-demo-up.sh runs them in order):
 *   warm  <rpc> <out.txt> [centerTicks]     the upstream reads the demo depends on, one line per call
 *                                           (centerTicks = "fee100,ref,v4pons,v4eth" — the bitmap centers to re-read)
 *   dump  <rpc> <out.json>                  write the running anvil's local state (anvil_dumpState)
 *   merge <dump.json> <forkBlock> <out.json> merge it with the flushed fork cache of <forkBlock>
 *
 * The 10 anvil dev accounts are EIP-7702-delegated on RHC mainnet (their keys are public); the merge
 * strips that delegation so they are plain EOAs locally, as on any anvil. The set also holds the stack's deployer,
 * anvil #200 (fork-demo-up.sh — unused on RHC, so no delegation today; listed so its balances are warmed and diffed
 * and a future delegation would be stripped too).
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { gunzipSync, zstdDecompressSync } from 'node:zlib';

const DEV_ACCOUNTS = new Set(
  [
    '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
    '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
    '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
    '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
    '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65',
    '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
    '0x976EA74026E726554dB657fA54763abd0C3a0aa9',
    '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
    '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f',
    '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
    '0xCD5691EA878D262516be278cb46f2fd7fF132083', // anvil #200 — the demo deployer / OWNER
  ].map((a) => a.toLowerCase()),
);

// Verified RHC addresses (notes/RHC_ADDRESSES.md).
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
const WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73';
const POOL = '0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca'; // v3 USDG/WETH fee 100, tickSpacing 1
// Vault "pons" (DemoLocalFork.s.sol): real PONS, the FablesRamp-hooked PONS/USDG v4 pool, its v3 TWAP reference.
const PONS = '0x39dBED3a2bd333467115dE45665cC57F813C4571';
const DEAD = '0x000000000000000000000000000000000000dEaD'; // the PONS funding source (fork-demo-up.sh)
const REF_POOL_PONS = '0x7A192E71564ec66eE0763e328a3Ac274942dE4e1'; // v3 PONS/USDG fee 10000, tickSpacing 200
const PM = '0x8366a39CC670B4001A1121B8F6A443A643e40951'; // v4 PoolManager
const UR = '0x204FAca1764B154221e35c0d20aBb3c525710498'; // UniversalRouter 2.1.2 — the hook's `sender` on adapter swaps
const HOOK = '0x08E52564Bad99E05a694b4809F397edcA417A080'; // FablesRamp (beforeInitialize + beforeSwap)
const PONS_POOL_ID = '0x486435a1f76cd58193f854c6e6213cd05fd58d637865d02065ff558b387fa6ea';
const PONS_KEY = { currency0: PONS, currency1: USDG, fee: 0x800000, tickSpacing: 60, hooks: HOOK };
// Vault "demo"'s native adapters: the ETH/USDG v4 pool with NATIVE ETH as currency0 behind FablesRampETH. The
// PoolManager custodies the pool's ETH, the PositionManager bridges WETH⇄ETH in-call (its own WETH9), and the native
// executor wraps/unwraps — so native balances and WETH (a transparent proxy) storage are warmed below too.
const POSM = '0x58daec3116aae6D93017bAAea7749052E8a04fA7'; // v4 PositionManager
const HOOK_ETH = '0x06a889870C8f83640D6816319f72e2aA579b6080'; // FablesRampETH (beforeInitialize + beforeSwap)
const ETH_POOL_ID = '0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551';
const ETH_KEY = { currency0: '0x0000000000000000000000000000000000000000', currency1: USDG, fee: 0x800000, tickSpacing: 10, hooks: HOOK_ETH };
const EIP1967_IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const V4_POOLS_SLOT = 6n; // PoolManager `_pools` (StateLibrary.POOLS_SLOT)
/** Tick-bitmap words read around the center (word = floor(tick / spacing) >> 8): ±2 words — ±512 ticks on the
 *  spacing-1 fee-100 pool (≈ ±5%), far wider on the spacing-200 reference and the spacing-60 v4 pool. */
const BITMAP_WORDS = 2;
// Selectors (`cast sig`).
const SEL = {
  name: '0x06fdde03',
  symbol: '0x95d89b41',
  decimals: '0x313ce567',
  totalSupply: '0x18160ddd',
  balanceOf: '0x70a08231',
  slot0: '0x3850c7bd',
  liquidity: '0x1a686502',
  fee: '0xddca3f43',
  tickSpacing: '0xd0c93a7c',
  feeGrowthGlobal0X128: '0xf3058399',
  feeGrowthGlobal1X128: '0x46141319',
  protocolFees: '0x1ad8b03b',
  token0: '0x0dfe1681',
  token1: '0xd21220a7',
  observations: '0x252c09d7',
  tickBitmap: '0x5339c296',
  ticks: '0xf30dba93',
  extsload: '0x1e2eaeaf',
  // FablesRamp views (poolId-keyed) + its beforeSwap (a view; PoolManager-only caller).
  currentFee: '0x15452022',
  autonomousFee: '0x725fec6f',
  maxFee: '0xb11dcb23',
  poolAsymmetry: '0x9d98c622',
  pokeOf: '0x966af35a',
  pokeFloor: '0x5cd04cf8',
  pausedFor: '0x8fdd4e6f',
  pausedUntilOf: '0xa00ba585',
  ABSOLUTE_MAX_FEE: '0x3c2f373f',
  MIN_POOL_FEE: '0xa6acaacc',
  MAX_POKE_TTL: '0x63cb7bdf',
  authority: '0xbf7e214f',
  beforeSwap: '0x575e24b4',
  flatFee: '0xd5a24724',
  paused: '0x5c975abb',
  pausedUntil: '0xda748b10',
  weth: '0x3fc8cef3',
  poolManager: '0xdc4c90d3',
  WETH9: '0x4aa4a4fc', // PositionManager (NativeWrapper)
  permit2: '0x12261ee7', // PositionManager
};

const die = (msg) => {
  console.error(`fork-demo-freeze: ${msg}`);
  process.exit(1);
};

/** ABI word for a (possibly negative) integer: 32-byte two's complement, no 0x. */
const word = (n) => (BigInt.asUintN(256, BigInt(n))).toString(16).padStart(64, '0');
const addrWord = (a) => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');
/** The i-th 32-byte word of a hex return value, as a signed / unsigned BigInt. */
const retWord = (hex, i, bits = 256, signed = false) => {
  const v = BigInt(`0x${hex.slice(2 + 64 * i, 2 + 64 * (i + 1)) || '0'}`);
  return signed ? BigInt.asIntN(bits, v) : BigInt.asUintN(bits, v);
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** eth_call a list of [label, to, data] in JSON-RPC batches; any final error aborts (a gap would be read as
 *  zero). The public RHC RPC rate-limits (HTTP 429) — batches are small and paced, and any batch containing
 *  a failed call is retried with a growing pause before giving up. */
async function callAll(rpc, calls) {
  const out = [];
  const BATCH = 25;
  for (let i = 0; i < calls.length; i += BATCH) {
    const chunk = calls.slice(i, i + BATCH);
    let results = null;
    for (let attempt = 0; attempt <= 6 && results === null; attempt++) {
      let body;
      try {
        const res = await fetch(rpc, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(
            chunk.map(([, to, data, from], j) => ({
              jsonrpc: '2.0',
              id: i + j,
              method: 'eth_call',
              params: [from ? { from, to, data } : { to, data }, 'latest'],
            })),
          ),
        });
        body = await res.json();
      } catch (e) {
        body = { error: { message: String(e) } };
      }
      const byId = new Map((Array.isArray(body) ? body : [body]).map((r) => [r && r.id, r]));
      const missing = chunk.filter((_c, j) => !byId.get(i + j) || byId.get(i + j).error);
      results = missing.length === 0 ? chunk.map((_c, j) => byId.get(i + j).result) : null;
      if (results === null) {
        if (attempt === 6) {
          const bad = byId.get(i + chunk.indexOf(missing[0]));
          die(`warm: ${missing[0][0]} failed: ${JSON.stringify(bad?.error ?? body)}`);
        }
        await sleep(700 * (attempt + 1)); // 0.7 s … 4.9 s — let the rate limit settle, then retry the batch
      }
    }
    chunk.forEach(([label], j) => out.push([label, results[j]]));
    if (i + BATCH < calls.length) await sleep(60); // pace: stay under the public RPC's rate limit
  }
  return out;
}

/** floor(tick / spacing) — Uniswap's compressed tick (rounds toward negative infinity). */
const compress = (tick, spacing) => Math.floor(tick / spacing);

/** keccak256(abi.encode(key, slot)) — a Solidity mapping slot (signed keys sign-extended), via foundry's `cast`. */
const mapSlot = (key, slot) => BigInt(execFileSync('cast', ['keccak', `0x${word(key)}${word(slot)}`], { encoding: 'utf8' }).trim());

/** A v3 pool's state, the newest ~1 h of its observations ring, its tick bitmap ±BITMAP_WORDS around `center` (default:
 *  its spot) and every initialized tick in those words — read as `<tag>.<fn>(…)` lines. Returns the lines + center. */
async function warmV3(rpc, tag, pool, center) {
  const base = await callAll(
    rpc,
    ['slot0', 'liquidity', 'fee', 'tickSpacing', 'feeGrowthGlobal0X128', 'feeGrowthGlobal1X128', 'protocolFees', 'token0', 'token1'].map(
      (f) => [`${tag}.${f}()`, pool, SEL[f]],
    ),
  );
  const slot0 = base.find(([l]) => l === `${tag}.slot0()`)[1];
  const spacing = Number(retWord(base.find(([l]) => l === `${tag}.tickSpacing()`)[1], 0, 24, true));
  const tick = Number(retWord(slot0, 1, 24, true));
  const index = retWord(slot0, 2, 16);
  const card = retWord(slot0, 3, 16);
  const mid = center === undefined ? tick : Number(center);

  // observe(lookback) binary-searches the ring from the newest entry backwards; the adapters' 1800 s guard
  // and the zap's 600 s guard only need entries inside a ~1 h window. Warm the NEWEST entries back to
  // newest − 3600 s (plus the one crossing the boundary): an unwarmed mid point reads ZERO on the frozen
  // node, which the search treats as "ancient" — it keeps moving its left bound right, so the converging
  // pair (the entry ≤ target and the next newer one) is found inside the warmed newest window. A 1 h
  // window + the boundary entry covers both guards for the demo's life (once frozen time passes
  // newest + 1800 s, observe() takes the fast path and reads the newest entry only).
  const WINDOW_S = 3600n;
  const cardN = Number(card);
  const idx = Number(index);
  const obsLabel = (i) => `${tag}.observations(${i})`;
  const newestTs = retWord((await callAll(rpc, [[obsLabel(idx), pool, SEL.observations + word(idx)]]))[0][1], 0, 64);
  const obs = [];
  walk: for (let k = 0; k < cardN; k += 25) {
    const chunk = [];
    for (let j = k; j < Math.min(k + 25, cardN); j++) chunk.push((idx - j + cardN) % cardN);
    const res = await callAll(rpc, chunk.map((i) => [obsLabel(i), pool, SEL.observations + word(i)]));
    for (const [label, hex] of res) {
      obs.push(Number(/\.observations\((\d+)\)$/.exec(label)[1]));
      if (newestTs - retWord(hex, 0, 64) >= WINDOW_S) break walk;
    }
  }
  const words = [];
  const midWord = compress(mid, spacing) >> 8;
  for (let w = midWord - BITMAP_WORDS; w <= midWord + BITMAP_WORDS; w++) words.push(w);
  const second = await callAll(rpc, [
    ...obs.map((i) => [obsLabel(i), pool, SEL.observations + word(i)]),
    ...words.map((w) => [`${tag}.tickBitmap(${w})`, pool, SEL.tickBitmap + word(w)]),
  ]);
  const ticks = [];
  for (const [label, hex] of second) {
    const m = /\.tickBitmap\((-?\d+)\)$/.exec(label);
    if (!m) continue;
    const bm = BigInt(hex);
    for (let b = 0; b < 256; b++) if ((bm >> BigInt(b)) & 1n) ticks.push((Number(m[1]) * 256 + b) * spacing);
  }
  const third = await callAll(rpc, ticks.map((t) => [`${tag}.ticks(${t})`, pool, SEL.ticks + word(t)]));
  return { lines: [...base, ...second, ...third], mid, words, ticks };
}

/** A v4 pool's state in the PoolManager (StateLibrary layout: `_pools[poolId]` = slot0, feeGrowthGlobal0/1,
 *  liquidity, ticks, tickBitmap, positions), read with `extsload`: the 4 header slots, the bitmap ±BITMAP_WORDS
 *  around `center` and the 3 slots of every initialized tick in it — what a swap on it walks. */
async function warmV4(rpc, tag, poolId, key, center) {
  const state = mapSlot(BigInt(poolId), V4_POOLS_SLOT);
  const ext = (label, slot) => [`${tag}.${label}`, PM, SEL.extsload + word(slot)];
  const head = await callAll(rpc, ['slot0', 'feeGrowthGlobal0X128', 'feeGrowthGlobal1X128', 'liquidity'].map((f, k) => ext(f, state + BigInt(k))));
  const slot0 = BigInt(head[0][1]);
  const tick = Number(BigInt.asIntN(24, slot0 >> 160n));
  const mid = center === undefined ? tick : Number(center);
  const spacing = key.tickSpacing;
  const words = [];
  const midWord = compress(mid, spacing) >> 8;
  for (let w = midWord - BITMAP_WORDS; w <= midWord + BITMAP_WORDS; w++) words.push(w);
  const bitmaps = await callAll(rpc, words.map((w) => ext(`tickBitmap(${w})`, mapSlot(w, state + 5n))));
  const ticks = [];
  bitmaps.forEach(([, hex], k) => {
    const bm = BigInt(hex);
    for (let b = 0; b < 256; b++) if ((bm >> BigInt(b)) & 1n) ticks.push((words[k] * 256 + b) * spacing);
  });
  const tickCalls = [];
  for (const t of ticks) {
    const base = mapSlot(t, state + 4n);
    for (let k = 0n; k < 3n; k++) tickCalls.push(ext(`ticks(${t})[${k}]`, base + k));
  }
  const tickInfo = await callAll(rpc, tickCalls);
  return { lines: [...head, ...bitmaps, ...tickInfo], mid, words, ticks };
}

/** A FablesRamp-family hook's reads for one pool: its poolId-keyed `views` (the two hooks differ — FablesRamp vs
 *  FablesRampETH), its no-arg `consts`, and `beforeSwap` itself (a view) called AS the PoolManager with the
 *  UniversalRouter as `sender` (every adapter swap's path), both directions × two sizes — whatever storage the hook
 *  resolves the fee from is fetched, without assuming its layout. */
async function warmHook(rpc, tag, hook, poolId, key, views, consts, sizes) {
  const pid = poolId.replace(/^0x/, '');
  const calls = [];
  for (const f of ['currentFee', ...views.filter((v) => v === 'autonomousFee')]) {
    for (const dir of [1, 0]) calls.push([`${tag}.${f}(pool,${dir === 1})`, hook, SEL[f] + pid + word(dir)]);
  }
  for (const f of views.filter((v) => v !== 'autonomousFee')) calls.push([`${tag}.${f}(pool)`, hook, SEL[f] + pid]);
  for (const f of consts) calls.push([`${tag}.${f}()`, hook, SEL[f]]);
  const MIN_SQRT_PLUS_1 = 4295128740n;
  const MAX_SQRT_MINUS_1 = 1461446703485210103287273052203988822378723970341n;
  for (const [zeroForOne, amountIn] of sizes) {
    const data =
      SEL.beforeSwap +
      addrWord(UR) +
      [addrWord(key.currency0), addrWord(key.currency1), word(key.fee), word(key.tickSpacing), addrWord(key.hooks)].join('') +
      [word(zeroForOne ? 1 : 0), word(-amountIn), word(zeroForOne ? MIN_SQRT_PLUS_1 : MAX_SQRT_MINUS_1)].join('') +
      word(10 * 32) + // offset of the (empty) hookData
      word(0);
    calls.push([`${tag}.beforeSwap(UR,${zeroForOne ? '0->1' : '1->0'},${amountIn})`, hook, data, PM]);
  }
  return callAll(rpc, calls);
}

/** Non-eth_call reads in one paced batch: [label, method, params]; any error aborts (a gap would read as zero). */
async function rpcAll(rpc, reqs) {
  const out = [];
  for (let i = 0; i < reqs.length; i += 25) {
    const chunk = reqs.slice(i, i + 25);
    let ok = null;
    for (let attempt = 0; attempt <= 6 && ok === null; attempt++) {
      let body;
      try {
        const res = await fetch(rpc, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(chunk.map(([, method, params], j) => ({ jsonrpc: '2.0', id: i + j, method, params }))),
        });
        body = await res.json();
      } catch (e) {
        body = { error: { message: String(e) } };
      }
      const byId = new Map((Array.isArray(body) ? body : [body]).map((r) => [r && r.id, r]));
      const bad = chunk.findIndex((_c, j) => !byId.get(i + j) || byId.get(i + j).error);
      if (bad === -1) ok = chunk.map(([label], j) => [label, byId.get(i + j).result]);
      else if (attempt === 6) die(`warm: ${chunk[bad][0]} failed: ${JSON.stringify(byId.get(i + bad)?.error ?? body)}`);
      else await sleep(700 * (attempt + 1));
    }
    out.push(...ok);
  }
  return out;
}

/** The native leg's plumbing: the PositionManager's WETH9 / Permit2 wiring, WETH's EIP-1967 implementation slot, and
 *  the NATIVE ETH balance of every account a native flow touches (the PoolManager custodies the pool's ETH). */
async function warmNative(rpc, holders) {
  const calls = await callAll(rpc, [
    ['posm.WETH9()', POSM, SEL.WETH9],
    ['posm.permit2()', POSM, SEL.permit2],
  ]);
  const raw = await rpcAll(rpc, [
    ['WETH.implSlot', 'eth_getStorageAt', [WETH, EIP1967_IMPL_SLOT, 'latest']],
    ...[...new Set([PM, POSM, WETH, UR, ...holders].map((h) => h.toLowerCase()))].map((h) => [`eth.balance(${h})`, 'eth_getBalance', [h, 'latest']]),
  ]);
  return [...calls, ...raw];
}

async function warm(rpc, outPath, centers) {
  const [cPool, cRef, cV4, cEth] = centers === undefined ? [] : String(centers).split(',').map((c) => (c === '' ? undefined : c));
  const holders = [POOL, DEAD, PM, POSM, UR, REF_POOL_PONS, ...DEV_ACCOUNTS];
  const calls = [];
  for (const [sym, t] of [['USDG', USDG], ['WETH', WETH], ['PONS', PONS]]) {
    for (const f of ['name', 'symbol', 'decimals', 'totalSupply']) calls.push([`${sym}.${f}()`, t, SEL[f]]);
    for (const h of holders) calls.push([`${sym}.balanceOf(${h})`, t, SEL.balanceOf + addrWord(h)]);
  }
  const base = await callAll(rpc, calls);
  const pool = await warmV3(rpc, 'pool', POOL, cPool);
  const ref = await warmV3(rpc, 'refPons', REF_POOL_PONS, cRef);
  const v4 = await warmV4(rpc, 'v4pons', PONS_POOL_ID, PONS_KEY, cV4);
  const v4eth = await warmV4(rpc, 'v4eth', ETH_POOL_ID, ETH_KEY, cEth);
  const E18 = 10n ** 18n;
  const E6 = 10n ** 6n;
  const hook = await warmHook(
    rpc, 'hook', HOOK, PONS_POOL_ID, PONS_KEY,
    ['autonomousFee', 'maxFee', 'poolAsymmetry', 'pokeOf', 'pokeFloor', 'pausedFor', 'pausedUntilOf'],
    ['ABSOLUTE_MAX_FEE', 'MIN_POOL_FEE', 'MAX_POKE_TTL', 'authority'],
    [[true, E18], [true, 10_000n * E18], [false, E6], [false, 5_000n * E6]],
  );
  const hookEth = await warmHook(
    rpc, 'hookEth', HOOK_ETH, ETH_POOL_ID, ETH_KEY,
    ['maxFee', 'pokeOf', 'pokeFloor', 'flatFee'],
    ['ABSOLUTE_MAX_FEE', 'MIN_POOL_FEE', 'MAX_POKE_TTL', 'authority', 'paused', 'pausedUntil', 'weth', 'poolManager'],
    [[true, E18 / 10n], [true, 20n * E18], [false, 100n * E6], [false, 50_000n * E6]],
  );
  const native = await warmNative(rpc, holders);

  const lines = [...base, ...pool.lines, ...ref.lines, ...v4.lines, ...v4eth.lines, ...hook, ...hookEth, ...native].map(
    ([l, r]) => `${l} ${typeof r === 'string' ? r : JSON.stringify(r)}`,
  );
  writeFileSync(outPath, `${lines.join('\n')}\n`);
  const dec = (sym) => Number(BigInt(base.find(([l]) => l === `${sym}.decimals()`)[1]));
  const span = (p) => `${p.ticks.length} initialized ticks in bitmap words ${p.words[0]}..${p.words.at(-1)}, center tick ${p.mid}`;
  console.log(
    `warm: ${lines.length} reads → ${outPath}\n` +
      `  fee-100 pool  : ${span(pool)}\n` +
      `  PONS ref (v3) : ${span(ref)}\n` +
      `  PONS v4 pool  : ${span(v4)}\n` +
      `  ETH v4 pool   : ${span(v4eth)} (native currency0)\n` +
      `  FablesRampETH : ${hookEth.length} reads · native plumbing ${native.length} reads (PM ETH ${BigInt(native.find(([l]) => l === `eth.balance(${PM.toLowerCase()})`)[1]) / E18} ETH)\n` +
      `  FablesRamp    : ${hook.length} reads · decimals USDG ${dec('USDG')} / WETH ${dec('WETH')} / PONS ${dec('PONS')}`,
  );
  console.log(`CENTER_TICK=${pool.mid},${ref.mid},${v4.mid},${v4eth.mid}`);
}

async function dump(rpc, out) {
  const res = await fetch(rpc, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_dumpState', params: [] }),
  });
  const body = await res.json();
  if (body.error || typeof body.result !== 'string') die(`anvil_dumpState failed: ${JSON.stringify(body.error ?? body)}`);
  const json = gunzipSync(Buffer.from(body.result.replace(/^0x/, ''), 'hex')).toString('utf8');
  writeFileSync(out, json);
  const state = JSON.parse(json);
  console.log(`dump: ${Object.keys(state.accounts).length} local accounts, best block ${state.best_block_number} → ${out}`);
}

/** foundry's on-disk fork cache for this block: ~/.foundry/cache/rpc/<chain>/<block>/storage-*.json (zstd). */
function findCache(forkBlock) {
  const root = join(homedir(), '.foundry', 'cache', 'rpc');
  const hits = [];
  for (const chain of existsSync(root) ? readdirSync(root) : []) {
    const dir = join(root, chain, String(forkBlock));
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) if (f.startsWith('storage')) hits.push(join(dir, f));
  }
  if (hits.length !== 1) die(`expected one fork cache for block ${forkBlock} under ${root}, found ${hits.length} (${hits.join(', ')})`);
  return hits[0];
}

function readCache(path) {
  const raw = readFileSync(path);
  const text = raw[0] === 0x28 && raw[1] === 0xb5 ? zstdDecompressSync(raw).toString('utf8') : raw.toString('utf8');
  return JSON.parse(text);
}

/** revm's cached bytecode → plain hex (analysed legacy code is zero-padded: cut to original_len). */
function codeHex(code) {
  if (code == null) return '0x';
  if (typeof code === 'string') return code;
  if (code.LegacyAnalyzed) return code.LegacyAnalyzed.bytecode.slice(0, 2 + 2 * code.LegacyAnalyzed.original_len);
  if (code.LegacyRaw) return code.LegacyRaw;
  if (code.Eip7702) return `0xef0100${code.Eip7702.delegated_address.replace(/^0x/, '').toLowerCase()}`;
  die(`unknown bytecode encoding ${Object.keys(code)[0]}`);
}

const toHexQty = (v) => (typeof v === 'number' ? `0x${v.toString(16)}` : v);

function merge(dumpPath, forkBlock, out) {
  const local = JSON.parse(readFileSync(dumpPath, 'utf8'));
  const cachePath = findCache(forkBlock);
  const cache = readCache(cachePath);

  const accounts = {};
  let fetched = 0;
  let slots = 0;
  let stripped = 0;
  for (const [addr, info] of Object.entries(cache.accounts)) {
    const a = addr.toLowerCase();
    let code = codeHex(info.code);
    if (DEV_ACCOUNTS.has(a) && code.startsWith('0xef0100')) {
      code = '0x';
      stripped++;
    }
    const storage = { ...(cache.storage[addr] ?? cache.storage[a] ?? {}) };
    slots += Object.keys(storage).length;
    accounts[a] = { nonce: Number(info.nonce), balance: toHexQty(info.balance), code, storage };
    fetched++;
  }
  // Fetched storage of accounts whose info was not cached separately (should not happen; kept for safety).
  for (const [addr, storage] of Object.entries(cache.storage)) {
    const a = addr.toLowerCase();
    if (!accounts[a]) accounts[a] = { nonce: 0, balance: '0x0', code: '0x', storage: { ...storage } };
  }

  // Local changes win: nonce / balance / code, and every locally written slot.
  let overlaid = 0;
  for (const [addr, info] of Object.entries(local.accounts)) {
    const a = addr.toLowerCase();
    const base = accounts[a];
    let code = info.code && info.code !== '0x' ? info.code : (base?.code ?? '0x');
    if (DEV_ACCOUNTS.has(a) && code.startsWith('0xef0100')) code = '0x';
    accounts[a] = {
      nonce: Number(info.nonce),
      balance: info.balance,
      code,
      storage: { ...(base?.storage ?? {}), ...(info.storage ?? {}) },
    };
    overlaid++;
  }

  const state = { ...local, accounts };
  writeFileSync(out, JSON.stringify(state));
  console.log(
    `merge: ${fetched} fetched accounts (${slots} slots) from ${cachePath}\n` +
      `       + ${overlaid} local accounts from ${dumpPath}; stripped ${stripped} dev-account 7702 delegations\n` +
      `       = ${Object.keys(accounts).length} accounts, best block ${local.best_block_number} → ${out}`,
  );
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'warm' && (args.length === 2 || args.length === 3)) await warm(args[0], args[1], args[2]);
else if (cmd === 'dump' && args.length === 2) await dump(args[0], args[1]);
else if (cmd === 'merge' && args.length === 3) merge(args[0], args[1], args[2]);
else die('usage: fork-demo-freeze.mjs warm <rpc> <out.txt> [centerTicks] | dump <rpc> <out.json> | merge <dump.json> <forkBlock> <out.json>');
