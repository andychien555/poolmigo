/**
 * The NAV history the off-chain collector writes (backend `collect-nav`): one JSON object per line,
 * appended hourly per deployed vault, ts ascending. No React, no network — the fetch lives in
 * ./useNavHistory.ts.
 *
 * Only the fields the chart needs are kept (`ts / chainId / vaultKey / navUsd`, plus `tvlUsd` /
 * `feesUsd` for later). The collector's USD is the same display-only spot valuation the app does
 * (docs/LIVE-DATA.md) — nothing here is an on-chain NAV.
 *
 * Imports are relative (not `@/`), like spot.ts: plain module, runnable under tsx.
 */

/** A real series needs at least this many snapshots for one vault; fewer → the chart stays illustrative. */
export const MIN_NAV_HISTORY_POINTS = 6;

/** One collector snapshot, reduced to what the app reads. */
export interface NavHistoryRow {
  /** Epoch ms of the snapshot. */
  t: number;
  /** The snapshot's ISO timestamp, as written. */
  ts: string;
  chainId: number;
  vaultKey: string;
  /** Spot NAV in USD; undefined when the collector could not price it (e.g. zero supply). */
  navUsd: number | undefined;
  tvlUsd: number | undefined;
  feesUsd: number | undefined;
}

/** One point of a vault's real NAV series. */
export interface NavHistoryPoint {
  t: number;
  ts: string;
  navUsd: number;
}

const num = (x: unknown): number | undefined => {
  const n = typeof x === 'string' && x.trim() !== '' ? Number(x) : x;
  return typeof n === 'number' && Number.isFinite(n) ? n : undefined;
};

/** One parsed line → a row, or undefined when it is not a usable snapshot. */
function toRow(o: unknown): NavHistoryRow | undefined {
  if (!o || typeof o !== 'object') return undefined;
  const r = o as Record<string, unknown>;
  const chainId = num(r.chainId);
  if (typeof r.ts !== 'string' || typeof r.vaultKey !== 'string' || chainId === undefined) return undefined;
  const t = Date.parse(r.ts);
  if (!Number.isFinite(t)) return undefined;
  return { t, ts: r.ts, chainId, vaultKey: r.vaultKey, navUsd: num(r.navUsd), tvlUsd: num(r.tvlUsd), feesUsd: num(r.feesUsd) };
}

/**
 * Parse the JSONL body line by line. Empty lines, a trailing partial line (the file is being appended
 * to) and any line that is not a snapshot are skipped — one bad line never loses the rest.
 */
export function parseNavHistoryJsonl(text: string): NavHistoryRow[] {
  const rows: NavHistoryRow[] = [];
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    let o: unknown;
    try {
      o = JSON.parse(s);
    } catch {
      continue;
    }
    const row = toRow(o);
    if (row) rows.push(row);
  }
  return rows;
}

/**
 * One vault's priced snapshots, oldest first (registry key on its chain: `main` / `pons` / `tri` on
 * 4663, `demo` / `pons` / `tri` on 46630). Sorted defensively; rows with no NAV are dropped.
 */
export function navHistoryFor(rows: readonly NavHistoryRow[], chainId: number, vaultKey: string): NavHistoryPoint[] {
  return rows
    .filter((r) => r.chainId === chainId && r.vaultKey === vaultKey && r.navUsd !== undefined && r.navUsd > 0)
    .map((r) => ({ t: r.t, ts: r.ts, navUsd: r.navUsd as number }))
    .sort((a, b) => a.t - b.t);
}
