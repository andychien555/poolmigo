/**
 * The vault's REAL LP ranges, as USDG prices for the range drawings. No React, no network.
 *
 * Every venue adapter holds one position and reports it with `positionState()` → (tokenId, lower tick,
 * upper tick, liquidity, configVersion); `id = 0` means no position. The ticks are in the adapter's own
 * pool tick domain, whose token0 / token1 the adapter exposes as `TOKEN0()` / `TOKEN1()` (the native-ETH
 * v4 adapter reports WETH as TOKEN0 — the stand-in for currency0 = native ETH, same 18 decimals).
 *
 * A tick becomes a price with TickMath (./ticks.ts) and then the same pool-ratio → USDG math the
 * reference-pool spot uses (./spot.ts `spotUsdPerToken`) — a tick bound is just a sqrt ratio.
 *
 * Bucketing follows the reference pools behind the spot prices: an adapter feeds the band of token T
 * only when its pool is the (T, USDG) pair, whichever venue it sits on. Adapters on any other pair
 * (e.g. ETH/PONS) carry no USDG bound and contribute nothing. Per token:
 *   lower = min over its adapters of the lower-bound price, upper = max of the upper-bound price.
 * A token with no live position has no band — the drawings then show nothing, never a made-up width.
 *
 * Imports are relative (not `@/`), like spot.ts: plain module, runnable under tsx.
 */
import { parseAbi, type Address } from 'viem';
import { spotUsdPerToken } from './spot';
import { getSqrtRatioAtTick, MAX_TICK, MIN_TICK } from './ticks';

/**
 * The adapter getters the band reads. Not on `IPositionAdapter` (shared/abis' generated fragment), but
 * every real venue adapter (v3, v4, v4 hooked, v4 native ETH) has them; a mock adapter does not, and its
 * failed reads simply contribute no band.
 */
export const adapterRangeAbi = parseAbi([
  'function positionState() view returns (uint256 id, int24 lower, int24 upper, uint128 liquidity, uint32 configVersion)',
  'function TOKEN0() view returns (address)',
  'function TOKEN1() view returns (address)',
]);

/** One adapter's live position, as read. */
export interface AdapterPosition {
  token0: Address;
  token1: Address;
  /** Position tokenId; 0 = no position. */
  id: bigint;
  tickLower: number;
  tickUpper: number;
}

/** A token's range in USDG per whole token. */
export interface PriceBand {
  lower: number;
  upper: number;
}

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * USDG per whole `token` at `tick` of a (token0, token1) pool, or undefined when the pool is not the
 * (token, anchor) pair or the tick is outside TickMath's domain.
 */
export function tickPriceInAnchor(
  tick: number,
  token: { address: Address; decimals: number },
  anchor: { address: Address; decimals: number },
  token0: Address,
  token1: Address,
): number | undefined {
  const tokenIsToken0 = same(token0, token.address) && same(token1, anchor.address);
  const tokenIsToken1 = same(token1, token.address) && same(token0, anchor.address);
  if (!(tokenIsToken0 || tokenIsToken1) || !Number.isInteger(tick) || tick < MIN_TICK || tick > MAX_TICK) return undefined;
  const sqrtPriceX96 = getSqrtRatioAtTick(tick);
  return spotUsdPerToken({ token: token.address, anchor: anchor.address, pool: token0, sqrtPriceX96, tokenIsToken0 }, token.decimals, anchor.decimals);
}

/**
 * Real bands per basket token (lowercase address → band), from the vault's adapters. Tokens with no
 * position on their (token, USDG) pair are absent. With token1 priced, a higher tick is a LOWER price,
 * so each adapter's two bounds are ordered before the min / max.
 */
export function priceBands(
  tokens: readonly { address: Address; symbol: string; decimals: number }[],
  anchorSymbol: string,
  positions: readonly AdapterPosition[],
): Map<string, PriceBand> {
  const out = new Map<string, PriceBand>();
  const anchor = tokens.find((t) => t.symbol === anchorSymbol);
  if (!anchor) return out;
  for (const t of tokens) {
    if (t === anchor) continue;
    for (const p of positions) {
      if (p.id === 0n || !(p.tickLower < p.tickUpper)) continue;
      const a = tickPriceInAnchor(p.tickLower, t, anchor, p.token0, p.token1);
      const b = tickPriceInAnchor(p.tickUpper, t, anchor, p.token0, p.token1);
      if (a === undefined || b === undefined) continue;
      const lo = Math.min(a, b), hi = Math.max(a, b);
      // A bound that floors to 0 or overflows a float (a near-full-range position) is no drawable band.
      if (!(lo > 0) || !Number.isFinite(hi)) continue;
      const key = t.address.toLowerCase();
      const prev = out.get(key);
      out.set(key, prev ? { lower: Math.min(prev.lower, lo), upper: Math.max(prev.upper, hi) } : { lower: lo, upper: hi });
    }
  }
  return out;
}
