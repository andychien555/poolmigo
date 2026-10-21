import { describe, expect, it } from 'vitest';
import type { Address } from 'viem';
import { anchorToUsd, quoteInAnchor, spotFromSlot0, spotUsdPerToken, valueBasket, type SpotPrice } from '@/chain/spot';

/* Robinhood Chain (4663) addresses and slot0 reads, captured 2026-10-19 (fixtures, not live). */
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as Address; // 6 dp
const WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' as Address; // 18 dp
const PONS = '0x39dBED3a2bd333467115dE45665cC57F813C4571' as Address; // 18 dp
const WETH_POOL = '0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca' as Address; // fee 100: token0 WETH, token1 USDG
const PONS_POOL = '0x7A192E71564ec66eE0763e328a3Ac274942dE4e1' as Address; // fee 10000: token0 PONS, token1 USDG
const WETH_SQRT = 3898977735850902606713713n;
const PONS_SQRT = 40521278812979596376244n;

const wethSpot = spotFromSlot0(WETH, USDG, WETH_POOL, WETH, USDG, WETH_SQRT, 100)!;
const ponsSpot = spotFromSlot0(PONS, USDG, PONS_POOL, PONS, USDG, PONS_SQRT, 10000)!;
const anchor = { address: USDG, decimals: 6 };
const spots = new Map<string, SpotPrice>([
  [WETH.toLowerCase(), wethSpot],
  [PONS.toLowerCase(), ponsSpot],
]);

describe('spotFromSlot0 — pair and price validation', () => {
  it('orients the pool: the priced token as token0 or token1', () => {
    expect(wethSpot.tokenIsToken0).toBe(true);
    expect(spotFromSlot0(WETH, USDG, WETH_POOL, USDG, WETH, WETH_SQRT)?.tokenIsToken0).toBe(false);
  });

  it('rejects a pool that is not exactly (token, anchor), and an uninitialised pool', () => {
    expect(spotFromSlot0(WETH, USDG, WETH_POOL, WETH, PONS, WETH_SQRT)).toBeUndefined();
    expect(spotFromSlot0(WETH, USDG, WETH_POOL, WETH, USDG, 0n)).toBeUndefined();
  });

  it('matches addresses case-insensitively', () => {
    expect(spotFromSlot0(WETH, USDG, WETH_POOL, WETH.toLowerCase() as Address, USDG.toUpperCase() as Address, WETH_SQRT)).toBeDefined();
  });
});

describe('quoteInAnchor — sqrtPriceX96² / 2¹⁹² across 18 → 6 decimals', () => {
  it('prices 1 WETH at the captured spot (≈ $2,421.8)', () => {
    // 1e18 · sqrt² / 2^192, in USDG base units.
    const raw = quoteInAnchor(10n ** 18n, wethSpot);
    expect(raw).toBe((10n ** 18n * WETH_SQRT * WETH_SQRT) / 2n ** 192n);
    expect(anchorToUsd(raw, 6)).toBeCloseTo(2421.8, 0);
    expect(spotUsdPerToken(wethSpot, 18, 6)).toBeCloseTo(2421.8, 0);
  });

  it('prices 1 PONS at the captured spot (≈ $0.2616)', () => {
    expect(spotUsdPerToken(ponsSpot, 18, 6)).toBeCloseTo(0.2616, 3);
  });

  it('inverts when the priced token is token1 (anchor is token0)', () => {
    // Same pool seen the other way: token1-per-token0 = 1 / (USDG per WETH), so sqrt' = 2^192 / sqrt.
    const inverted = spotFromSlot0(WETH, USDG, WETH_POOL, USDG, WETH, 2n ** 192n / WETH_SQRT)!;
    const a = quoteInAnchor(10n ** 18n, wethSpot);
    const b = quoteInAnchor(10n ** 18n, inverted);
    expect(Number(b) / Number(a)).toBeCloseTo(1, 6);
  });

  it('floors: dust below one USDG unit quotes to zero, never up', () => {
    expect(quoteInAnchor(1n, wethSpot)).toBe(0n);
    expect(quoteInAnchor(0n, wethSpot)).toBe(0n);
  });
});

describe('valueBasket — USDG at $1 peg + spot legs', () => {
  it('values the tri basket (USDG / WETH / PONS) and splits shares', () => {
    // sunTriLP totalTokens() on 2026-10-19.
    const v = valueBasket(
      [
        { address: USDG, symbol: 'USDG', decimals: 6, total: 54_573_636n },
        { address: WETH, symbol: 'WETH', decimals: 18, total: 12_230_138_091_112_566n },
        { address: PONS, symbol: 'PONS', decimals: 18, total: 25_023_112_832_352_123_734n },
      ],
      anchor,
      spots,
    );
    expect(v.unpriced).toEqual([]);
    expect(v.legs[0].usd).toBeCloseTo(54.573636, 6);
    expect(v.legs[1].usd).toBeCloseTo(29.62, 1);
    expect(v.legs[2].usd).toBeCloseTo(6.55, 1);
    expect(v.usd).toBeCloseTo(90.74, 0);
    const shares = v.legs.map((l) => l.share!);
    expect(shares.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 9);
    expect(v.legs[1].spot?.pool).toBe(WETH_POOL);
    expect(v.legs[0].spot).toBeUndefined();
  });

  it('omits the TVL (not a partial sum) when a held token has no spot', () => {
    const v = valueBasket(
      [
        { address: USDG, symbol: 'USDG', decimals: 6, total: 1_000_000n },
        { address: PONS, symbol: 'PONS', decimals: 18, total: 10n ** 18n },
      ],
      anchor,
      new Map([[WETH.toLowerCase(), wethSpot]]),
    );
    expect(v.usd).toBeUndefined();
    expect(v.unpriced).toEqual(['PONS']);
    expect(v.legs[0].usd).toBe(1);
    expect(v.legs.every((l) => l.share === undefined)).toBe(true);
  });

  it('needs no price for a zero balance, and nothing is priced without an anchor', () => {
    const zero = valueBasket([{ address: PONS, symbol: 'PONS', decimals: 18, total: 0n }], anchor, new Map());
    expect(zero).toEqual({ usd: 0, legs: [{ usd: 0, share: 0 }], unpriced: [] });
    const noAnchor = valueBasket([{ address: WETH, symbol: 'WETH', decimals: 18, total: 1n }], undefined, spots);
    expect(noAnchor.usd).toBeUndefined();
    expect(noAnchor.unpriced).toEqual(['WETH']);
  });

  it('rejects a spot quoted against a different anchor', () => {
    const other = { address: PONS, decimals: 18 };
    const v = valueBasket([{ address: WETH, symbol: 'WETH', decimals: 18, total: 10n ** 18n }], other, spots);
    expect(v.unpriced).toEqual(['WETH']);
  });
});
