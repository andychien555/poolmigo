/**
 * The fee APR (the original design's "Your APR: from trading fees, the 7-day average, annualised"),
 * from the NAV-history collector's rows (./navHistory.ts). Pure: no React, no network.
 *
 * `feesUsd` is the vault's CUMULATIVE harvested fees (monotone), snapshotted hourly, so Δfees over a
 * window is the window's accrual. The yield is fees ÷ TVL — never the NAV slope, which goes negative
 * whenever a basket token's price drops. A series shorter than the window → undefined (rendered "—";
 * never a fabricated figure).
 *
 * Imports are relative (not `@/`), like navHistory.ts: plain module, runnable under tsx.
 */
import type { NavHistoryRow } from './navHistory';

const DAY_MS = 86_400_000;

/** The window the design draws: the 7-day average. */
export const FEE_APR_WINDOW_DAYS = 7;

/** One snapshot of a vault's fee series. */
export interface FeePoint {
  t: number;
  feesUsd: number;
  tvlUsd: number;
}

/**
 * One vault's snapshots that carry both cumulative fees and TVL, oldest first (any input order).
 * `chainId` narrows the cut: a vault key (`pons`, `tri`) repeats across chains in the cross-chain file.
 */
export function feeSeriesFor(rows: readonly NavHistoryRow[], vaultKey: string, chainId?: number): FeePoint[] {
  return rows
    .filter((r) => r.vaultKey === vaultKey && (chainId === undefined || r.chainId === chainId) && r.feesUsd !== undefined && r.tvlUsd !== undefined)
    .map((r) => ({ t: r.t, feesUsd: r.feesUsd as number, tvlUsd: r.tvlUsd as number }))
    .sort((a, b) => a.t - b.t);
}

/**
 * Annualised fee yield over the last `windowDays` of the series, as a fraction (0.05 = 5%):
 * Δfees (last − the last row at or before `lastTs − window`, clamped ≥ 0) ÷ the mean TVL of the rows
 * from that boundary through the last, × 365 ÷ windowDays. Simple annualisation, no compounding.
 * undefined when the series does not cover the window, or the mean TVL is not positive.
 */
export function feeApy(rows: readonly NavHistoryRow[], vaultKey: string, windowDays: number, chainId?: number): number | undefined {
  const s = feeSeriesFor(rows, vaultKey, chainId);
  const last = s[s.length - 1];
  if (!last || !(windowDays > 0)) return undefined;
  const cutoff = last.t - windowDays * DAY_MS;
  let b = -1;
  for (let i = s.length - 1; i >= 0; i--) {
    if (s[i].t <= cutoff) {
      b = i;
      break;
    }
  }
  if (b < 0) return undefined;
  const inWindow = s.slice(b);
  const avgTvl = inWindow.reduce((sum, p) => sum + p.tvlUsd, 0) / inWindow.length;
  if (!(avgTvl > 0)) return undefined;
  const dFees = Math.max(0, last.feesUsd - s[b].feesUsd);
  return ((dFees / avgTvl) * 365) / windowDays;
}

/** {@link feeApy} as a percent rounded to 2 decimals (5.123% → 5.12), or undefined. */
export function feeApyPct(rows: readonly NavHistoryRow[], vaultKey: string, windowDays: number, chainId?: number): number | undefined {
  const apy = feeApy(rows, vaultKey, windowDays, chainId);
  return apy === undefined ? undefined : Math.round(apy * 100 * 100) / 100;
}

/** The vault's latest cumulative harvested fees in USD, or undefined without a snapshot carrying them. */
export function latestFeesUsd(rows: readonly NavHistoryRow[], vaultKey: string, chainId?: number): number | undefined {
  const s = feeSeriesFor(rows, vaultKey, chainId);
  return s[s.length - 1]?.feesUsd;
}

/** A percent from {@link feeApyPct} for display: "0.00%", or "—" when undefined. */
export function fmtFeeApr(pct: number | undefined): string {
  return pct === undefined ? '—' : `${pct.toFixed(2)}%`;
}
