/**
 * The fee APR (TASK-FEE-APR): Δ cumulative fees over the window ÷ the window's mean TVL, × 365 ÷ days.
 * Window-boundary pick, short series → undefined, zero accrual → 0.00%, negative Δ clamped, and two
 * windows over the same series.
 */
import { describe, expect, it } from 'vitest';
import type { NavHistoryRow } from '@/chain/navHistory';
import { feeApy, feeApyPct, feeSeriesFor, fmtFeeApr, latestFeesUsd } from '@/chain/feeApy';

const T0 = Date.parse('2026-10-01T00:00:00.000Z');
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

function row(t: number, feesUsd: number | undefined, tvlUsd: number | undefined = 1000, over: Partial<NavHistoryRow> = {}): NavHistoryRow {
  return { t, ts: new Date(t).toISOString(), chainId: 4663, vaultKey: 'main', navUsd: 1, tvlUsd, feesUsd, ...over };
}

/** Hourly snapshots for `days` days, fees accruing `perDay` USD/day at a flat TVL. */
function hourly(days: number, perDay: number, tvl = 1000, over: Partial<NavHistoryRow> = {}): NavHistoryRow[] {
  return Array.from({ length: days * 24 + 1 }, (_, i) => row(T0 + i * HOUR, (perDay * i) / 24, tvl, over));
}

describe('feeApy', () => {
  it('picks the last row at or before lastTs − window as the boundary', () => {
    // Rows at day 0, 0.5, 1, 7.5 (last). Window 7d → cutoff 0.5d → boundary is the 0.5d row (fees 10),
    // not day 0 (fees 0) nor day 1 (fees 50). Inside: 0.5d, 1d, 7.5d → TVL mean (1000+2000+3000)/3.
    const rows = [row(T0, 0, 500), row(T0 + 0.5 * DAY, 10, 1000), row(T0 + DAY, 50, 2000), row(T0 + 7.5 * DAY, 80, 3000)];
    expect(feeApy(rows, 'main', 7)).toBeCloseTo(((80 - 10) / 2000) * (365 / 7), 12);
    // Any input order: sorted inside.
    expect(feeApy([...rows].reverse(), 'main', 7)).toBeCloseTo(((80 - 10) / 2000) * (365 / 7), 12);
  });

  it('a row exactly at the cutoff is the boundary (ts <= cutoff)', () => {
    const rows = [row(T0, 0), row(T0 + DAY, 7), row(T0 + 8 * DAY, 14)];
    expect(feeApy(rows, 'main', 7)).toBeCloseTo((7 / 1000) * (365 / 7), 12);
  });

  it('a series shorter than the window → undefined (never fabricated)', () => {
    expect(feeApy(hourly(6, 1), 'main', 7)).toBeUndefined();
    expect(feeApyPct(hourly(6, 1), 'main', 7)).toBeUndefined();
    expect(feeApy([], 'main', 7)).toBeUndefined();
    expect(feeApy([row(T0, 1)], 'main', 7)).toBeUndefined();
    expect(fmtFeeApr(undefined)).toBe('—');
  });

  it('zero accrual → 0, rendered 0.00%', () => {
    const rows = hourly(8, 0);
    expect(feeApy(rows, 'main', 7)).toBe(0);
    expect(feeApyPct(rows, 'main', 7)).toBe(0);
    expect(fmtFeeApr(feeApyPct(rows, 'main', 7))).toBe('0.00%');
  });

  it('a negative Δfees is clamped to 0', () => {
    const rows = [row(T0, 5), row(T0 + 7 * DAY, 3)];
    expect(feeApy(rows, 'main', 7)).toBe(0);
  });

  it('two windows over a steady accrual agree; different rates differ', () => {
    // $1/day on $1000 TVL → 36.5% a year, whatever the window.
    const steady = hourly(30, 1);
    expect(feeApyPct(steady, 'main', 7)).toBe(36.5);
    expect(feeApyPct(steady, 'main', 30)).toBe(36.5);
    // Fees only in the last 7 days ($2/day): the 7D window reads 73%, the 14D window half that.
    const late = Array.from({ length: 14 * 24 + 1 }, (_, i) => row(T0 + i * HOUR, i <= 7 * 24 ? 0 : (2 * (i - 7 * 24)) / 24));
    expect(feeApyPct(late, 'main', 7)).toBe(73);
    expect(feeApyPct(late, 'main', 14)).toBe(36.5);
    expect(fmtFeeApr(feeApyPct(late, 'main', 7))).toBe('73.00%');
  });

  it('rounds the percent to 2 decimals', () => {
    // Δ 1 on $3000 over 7d → 1.7380952…%
    const rows = [row(T0, 0, 3000), row(T0 + 7 * DAY, 1, 3000)];
    expect(feeApyPct(rows, 'main', 7)).toBe(1.74);
  });

  it('cuts per vault (and per chain when given); rows without fees or TVL are skipped', () => {
    const rows = [...hourly(8, 1), ...hourly(8, 5, 1000, { vaultKey: 'pons' }), ...hourly(8, 9, 1000, { vaultKey: 'pons', chainId: 46630 })];
    expect(feeApyPct(rows, 'main', 7)).toBe(36.5);
    expect(feeApyPct(rows, 'pons', 7, 4663)).toBe(182.5);
    expect(feeApyPct(rows, 'pons', 7, 46630)).toBe(328.5);
    expect(feeSeriesFor([row(T0, undefined), row(T0 + HOUR, 1, 1000, { tvlUsd: undefined }), row(T0 + 2 * HOUR, 2)], 'main')).toHaveLength(1);
  });

  it('latestFeesUsd is the newest cumulative figure', () => {
    expect(latestFeesUsd([row(T0 + HOUR, 0.00096), row(T0, 0.0005)], 'main', 4663)).toBe(0.00096);
    expect(latestFeesUsd([], 'main')).toBeUndefined();
  });
});
