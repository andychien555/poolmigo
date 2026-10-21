/**
 * A vault's real NAV series from the collector's JSONL (parsing in ./navHistory.ts). Wallet-independent.
 *
 * The source URL is build-time (`VITE_NAV_HISTORY_URL`); unset → `hasSource: false` and nothing is
 * fetched, so the chart keeps its illustrative line. One fetch serves every vault on every chain (the
 * file is cross-chain), so the cache key is the URL; the per-vault cut is a memo on (chainId, vaultKey).
 * A failed fetch or too few snapshots (< MIN_NAV_HISTORY_POINTS) → `isReal: false`.
 */
import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { MIN_NAV_HISTORY_POINTS, navHistoryFor, parseNavHistoryJsonl, type NavHistoryPoint, type NavHistoryRow } from './navHistory';

/** Empty string when unset. */
export const NAV_HISTORY_URL: string = (import.meta.env.VITE_NAV_HISTORY_URL ?? '').trim();

/** The collector snapshots hourly; re-reading more often than this buys nothing. */
const STALE_MS = 5 * 60_000;

export interface NavHistory {
  /** A collector URL is configured. */
  hasSource: boolean;
  /** This vault's priced snapshots, oldest first (empty while loading, on error, or without a source). */
  points: NavHistoryPoint[];
  /** Enough snapshots to draw the real series instead of the illustrative one. */
  isReal: boolean;
  isLoading: boolean;
}

async function fetchNavHistory(url: string, signal: AbortSignal) {
  const res = await fetch(url, { signal });
  if (!res.ok) throw new Error(`NAV history: HTTP ${res.status}`);
  return parseNavHistoryJsonl(await res.text());
}

export interface NavHistoryRows {
  hasSource: boolean;
  /** Every parsed collector row, all chains and vaults (empty while loading, on error, or without a source). */
  rows: NavHistoryRow[];
  isLoading: boolean;
}

const NO_ROWS: NavHistoryRow[] = [];

/**
 * The whole collector file. Every consumer (the NAV chart, the fee APR on the Earn table and the vault
 * page) reads through this one query — same key, same cache, one fetch on a 5-min cadence.
 */
export function useNavHistoryRows(url: string = NAV_HISTORY_URL): NavHistoryRows {
  const hasSource = url.length > 0;
  const query = useQuery({
    queryKey: ['navHistory', url],
    queryFn: ({ signal }) => fetchNavHistory(url, signal),
    enabled: hasSource,
    staleTime: STALE_MS,
    refetchInterval: STALE_MS,
  });
  return { hasSource, rows: query.data ?? NO_ROWS, isLoading: hasSource && query.isLoading };
}

export function useNavHistory(chainId: number, vaultKey: string, url: string = NAV_HISTORY_URL): NavHistory {
  const { hasSource, rows, isLoading } = useNavHistoryRows(url);
  const points = useMemo(() => navHistoryFor(rows, chainId, vaultKey), [rows, chainId, vaultKey]);
  return { hasSource, points, isReal: hasSource && points.length >= MIN_NAV_HISTORY_POINTS, isLoading };
}
