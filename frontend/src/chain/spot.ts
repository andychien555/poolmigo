/**
 * Spot-price display math for the live vault table. No React, no network.
 *
 * USD here is OFF-CHAIN DISPLAY ONLY (monorepo invariant): the vault never values anything. The table
 * converts each basket total into the anchor token (USDG, shown at its $1 peg) through the LIVE spot of
 * a Uniswap v3 reference pool — `slot0().sqrtPriceX96`, nothing else. No oracle, no TWAP (RHC v3
 * observations are degenerate chain-wide; the price book itself is live).
 *
 * The reference pool is the one the chain's zap periphery routes through (`routes(USDG, token).refPool`),
 * so the table prices a token where the protocol's own config says to. A token with no such pool is not
 * priced: its leg — and the vault's TVL — is omitted, never estimated.
 *
 * Math (Uniswap v3: price = token1 per token0 in raw units = sqrtPriceX96² / 2¹⁹²), all in bigint:
 *   token is token0:  anchorRaw = amount · sqrtPriceX96² / 2¹⁹²
 *   token is token1:  anchorRaw = amount · 2¹⁹² / sqrtPriceX96²
 * Raw units carry the decimals (USDG 6 dp, WETH / PONS 18 dp), so no scaling step is needed; the only
 * float is the final anchorRaw / 10^anchorDecimals for display.
 *
 * Imports are relative (not `@/`), like zap.ts: plain module, runnable under tsx.
 */
import { parseAbi, type Address } from 'viem';

/** The token the table prices everything in, matched on the basket by symbol (as the zap facets do). */
export const USD_ANCHOR_SYMBOL = 'USDG';

/**
 * The two Uniswap v3 pool getters the table reads. Not a MySun artifact (shared/abis carries only our
 * own contracts), so the minimal fragment is declared here. Only `sqrtPriceX96` of `slot0` is used.
 */
export const v3PoolAbi = parseAbi([
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function fee() view returns (uint24)',
  'function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)',
]);

const Q192 = 2n ** 192n;

/** One token's live spot against the anchor, as read from its reference pool. */
export interface SpotPrice {
  token: Address;
  anchor: Address;
  pool: Address;
  /** Pool fee in pips (100 = 0.01%), for the label only. */
  fee?: number;
  sqrtPriceX96: bigint;
  /** The priced token is the pool's token0 (else token1). */
  tokenIsToken0: boolean;
}

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * A spot from a pool's `token0` / `token1` / `slot0` reads — or undefined when the pool is not exactly
 * the (token, anchor) pair or has no price (uninitialised: sqrtPriceX96 = 0).
 */
export function spotFromSlot0(
  token: Address,
  anchor: Address,
  pool: Address,
  token0: Address,
  token1: Address,
  sqrtPriceX96: bigint,
  fee?: number,
): SpotPrice | undefined {
  if (sqrtPriceX96 <= 0n) return undefined;
  const tokenIsToken0 = same(token0, token) && same(token1, anchor);
  const tokenIsToken1 = same(token1, token) && same(token0, anchor);
  if (!tokenIsToken0 && !tokenIsToken1) return undefined;
  return { token, anchor, pool, fee, sqrtPriceX96, tokenIsToken0 };
}

/** `amount` (token base units) → anchor base units at the spot, floored. */
export function quoteInAnchor(amount: bigint, spot: SpotPrice): bigint {
  const p2 = spot.sqrtPriceX96 * spot.sqrtPriceX96;
  return spot.tokenIsToken0 ? (amount * p2) / Q192 : (amount * Q192) / p2;
}

/** Anchor base units → a display number in whole anchor tokens (USDG at its $1 peg = USD). */
export function anchorToUsd(raw: bigint, anchorDecimals: number): number {
  return Number(raw) / 10 ** anchorDecimals;
}

/** USD per ONE whole token at the spot (display: the price the table used). */
export function spotUsdPerToken(spot: SpotPrice, tokenDecimals: number, anchorDecimals: number): number {
  // Quote 10^dec token units, with 10^6 extra anchor precision so sub-cent prices survive the floor.
  const scale = 10n ** 6n;
  return anchorToUsd(quoteInAnchor(10n ** BigInt(tokenDecimals) * scale, spot), anchorDecimals) / 1e6;
}

export interface BasketLegInput {
  address: Address;
  symbol: string;
  decimals: number;
  /** The vault total (`totalTokens`) for this token. */
  total: bigint;
}

export interface BasketLeg {
  /** USD at spot; undefined when the token has a balance but no reference pool. */
  usd: number | undefined;
  /** Share of the vault's USD value (0..1); undefined when the TVL itself is unknown. */
  share: number | undefined;
  /** The spot used for this leg (none for the anchor itself, or an unpriced token). */
  spot?: SpotPrice;
}

export interface BasketValuation {
  /** Σ leg USD; undefined unless EVERY non-zero leg is priced (a partial sum is never shown as TVL). */
  usd: number | undefined;
  legs: BasketLeg[];
  /** Symbols of tokens with a balance but no usable reference pool. */
  unpriced: string[];
}

/**
 * Value a basket at spot. `anchor` is the basket's USDG (undefined → nothing can be priced). `spots`
 * maps a token address (lowercase) to its spot against that anchor. A zero balance needs no price.
 */
export function valueBasket(
  legsIn: readonly BasketLegInput[],
  anchor: { address: Address; decimals: number } | undefined,
  spots: ReadonlyMap<string, SpotPrice>,
): BasketValuation {
  const unpriced: string[] = [];
  const legs = legsIn.map((t): Omit<BasketLeg, 'share'> => {
    if (t.total === 0n) return { usd: 0 };
    if (anchor && same(t.address, anchor.address)) return { usd: anchorToUsd(t.total, anchor.decimals) };
    const spot = anchor ? spots.get(t.address.toLowerCase()) : undefined;
    if (!anchor || !spot || !same(spot.anchor, anchor.address)) {
      unpriced.push(t.symbol);
      return { usd: undefined };
    }
    return { usd: anchorToUsd(quoteInAnchor(t.total, spot), anchor.decimals), spot };
  });
  const usd = unpriced.length === 0 ? legs.reduce((s, l) => s + (l.usd ?? 0), 0) : undefined;
  return {
    usd,
    legs: legs.map((l) => ({ ...l, share: usd === undefined ? undefined : usd > 0 ? (l.usd ?? 0) / usd : 0 })),
    unpriced,
  };
}
