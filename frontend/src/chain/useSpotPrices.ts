/**
 * Live reference-pool spots for one chain's basket tokens — the price input of the live vault table
 * (math and rules in ./spot.ts). Wallet-independent.
 *
 * Two rounds on the chain's own RPC client:
 *  1. `zapIn.routes(USDG, token).refPool` for every non-USDG basket token — the reference pool the
 *     protocol's zap config already uses. No periphery on the chain, or no route → no price.
 *  2. `token0 / token1 / fee / slot0` of each distinct reference pool.
 * Cache keys: chainId + the zap address as scope + the calls (which name every pool / token address).
 */
import { useMemo } from 'react';
import type { Address } from 'viem';
import { zapInAbi } from '@/config/generated';
import type { ChainDeployment } from './chains';
import { spotFromSlot0, v3PoolAbi, type SpotPrice } from './spot';
import { pick, useReads } from './useReads';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

export interface ChainSpots {
  /** Lowercase token address → its spot against `anchor`. */
  spots: ReadonlyMap<string, SpotPrice>;
  isLoading: boolean;
}

/** `anchor` = the chain's USDG (undefined → nothing to price); `tokens` = the other basket tokens. */
export function useSpotPrices(
  deployment: ChainDeployment,
  anchor: Address | undefined,
  tokens: readonly Address[],
): ChainSpots {
  const zap = deployment.periphery?.zapIn;
  const chainId = deployment.chainId;
  // Distinct, stable order (the key must not churn with vault order).
  const others = useMemo(
    () =>
      [...new Set(tokens.map((t) => t.toLowerCase()))]
        .filter((t) => anchor && t !== anchor.toLowerCase())
        .sort() as Address[],
    [tokens.join(','), anchor],
  );

  const routeReads = useReads(
    zap && anchor
      ? others.map((t) => ({ address: zap, abi: zapInAbi, functionName: 'routes', args: [anchor, t] }) as const)
      : [],
    { chainId, scope: `spot:${zap ?? 'none'}`, enabled: Boolean(zap && anchor) && others.length > 0 },
  );

  const pools = others.map((_, i) => {
    const pool = pick<readonly [Address, ...unknown[]]>(routeReads.data, i)?.[0];
    return pool && pool !== ZERO_ADDRESS ? pool : undefined;
  });
  const distinctPools = [...new Set(pools.filter((p): p is Address => p !== undefined))];

  const poolReads = useReads(
    distinctPools.flatMap((p) => [
      { address: p, abi: v3PoolAbi, functionName: 'token0' } as const,
      { address: p, abi: v3PoolAbi, functionName: 'token1' } as const,
      { address: p, abi: v3PoolAbi, functionName: 'fee' } as const,
      { address: p, abi: v3PoolAbi, functionName: 'slot0' } as const,
    ]),
    { chainId, scope: `spot:${zap ?? 'none'}`, enabled: distinctPools.length > 0 },
  );

  const spots = useMemo(() => {
    const out = new Map<string, SpotPrice>();
    if (!anchor) return out;
    others.forEach((token, i) => {
      const pool = pools[i];
      if (!pool) return;
      const j = distinctPools.indexOf(pool) * 4;
      const token0 = pick<Address>(poolReads.data, j);
      const token1 = pick<Address>(poolReads.data, j + 1);
      const fee = pick<number>(poolReads.data, j + 2);
      const slot0 = pick<readonly [bigint, ...unknown[]]>(poolReads.data, j + 3);
      if (!token0 || !token1 || !slot0) return;
      const spot = spotFromSlot0(token, anchor, pool, token0, token1, slot0[0], fee === undefined ? undefined : Number(fee));
      if (spot) out.set(token.toLowerCase(), spot);
    });
    return out;
  }, [anchor, others.join(','), pools.join(','), poolReads.data]);

  return { spots, isLoading: routeReads.isLoading || poolReads.isLoading };
}
