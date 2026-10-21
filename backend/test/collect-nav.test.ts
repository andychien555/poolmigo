import { describe, expect, it } from 'vitest';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { priceUsdFromSpot, sweepData } from '../src/collect-nav.js';

const Q192 = 2n ** 192n;

describe('priceUsdFromSpot', () => {
  it('prices a token0-priced pool (WETH as token0 vs USDG token1, ~2400 USDG/WETH)', () => {
    // ratio (raw USDG per raw WETH) = 2400e6 / 1e18 = 2.4e-9 -> sqrt = sqrt(2.4e-9 * 2^192)
    const sqrt = BigInt(Math.round(Math.sqrt(2.4e-9 * Number(Q192))));
    const px = priceUsdFromSpot(sqrt, true, 18);
    expect(px).toBeGreaterThan(2399);
    expect(px).toBeLessThan(2401);
  });

  it('prices a 1:1 token1-priced pool (anchor token0, priced token1, both 6 dp)', () => {
    // 1 raw token0 = 1 raw token1 -> sqrt = 2^96 -> 1 whole token1 = 1 whole anchor (price 1).
    const oneToOne = 2n ** 96n;
    expect(priceUsdFromSpot(oneToOne, false, 6)).toBeCloseTo(1, 9);
  });

  it('handles the mainnet WETH/USDG sqrt without overflow or zero (bigint multiply-first)', () => {
    // The live pool's sqrt (~3.887e24). A ratio-first bigint division would floor to 0.
    const sqrt = 3_887_318_158_863_755_502_419_968n;
    const px = priceUsdFromSpot(sqrt, true, 18);
    expect(Number.isFinite(px)).toBe(true);
    expect(px).toBeGreaterThan(2000); // ~2400 USDG per WETH at that sqrt
    expect(px).toBeLessThan(3000);
  });

  it('returns NaN for an uninitialised pool (sqrt = 0)', () => {
    expect(priceUsdFromSpot(0n, true, 18)).toBeNaN();
  });
});

describe('sweepData', () => {
  const GOOD = {
    chainId: 4663,
    vaultKey: 'tri',
    supply: '182048430611964210314',
    navUsd: 0.932,
    tokens: [
      { symbol: 'USDG', decimals: 6, totalRaw: '101315142', priceUsd: 1 },
      { symbol: 'WETH', decimals: 18, totalRaw: '28500000000000000', priceUsd: 2400 },
    ],
  };
  const JUMP = { ...GOOD, navUsd: 0.26 }; // tvl 0.26 vs 0.93 repriced — impossible without a broken read
  const MISSING = { ...GOOD, tokens: [{ ...GOOD.tokens[0] }, { symbol: 'PONS', decimals: 18, totalRaw: '1', priceUsd: null }] };
  const QMARK = { ...GOOD, tokens: [{ ...GOOD.tokens[0], symbol: '?' }, GOOD.tokens[1]] };
  // A real price move (PONS +20%, same totals) re-prices the vault and must NOT be swept.
  const MOVED = {
    ...GOOD,
    navUsd: 1.0074, // 101.315 + 0.0285×2880 = 183.4 / 182.05
    tokens: [{ ...GOOD.tokens[0] }, { ...GOOD.tokens[1], priceUsd: 2880 }],
  };

  it('drops broken rows (null price, "?" symbol) and impossible residuals, keeps real moves', async () => {
    const dir = await mkdtemp('mysun-sweep-');
    const file = join(dir, 'collect-nav.jsonl');
    try {
      const prevEnv = process.env.DATA_DIR;
      process.env.DATA_DIR = dir;
      try {
        await writeFile(file, [GOOD, JUMP, MOVED, MISSING, QMARK, GOOD].map((r) => JSON.stringify(r)).join('\n') + '\n');
        const dropped = sweepData();
        expect(dropped).toBe(3);
        const kept = await readFile(file, 'utf8').then((s) => s.trim().split('\n').filter(Boolean));
        expect(kept).toHaveLength(3);
      } finally {
        if (prevEnv === undefined) delete process.env.DATA_DIR;
        else process.env.DATA_DIR = prevEnv;
      }
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});