/**
 * A vault's real LP range per basket token (math and bucketing rules in ./ranges.ts). Wallet-independent.
 *
 * Two rounds on the vault's chain:
 *  1. `adapters()` of the vault;
 *  2. `positionState / TOKEN0 / TOKEN1` of every adapter.
 * A failed read (an unreachable chain, a mock adapter without these getters) contributes no band.
 * Cache keys: chainId + the vault address as scope + the calls.
 */
import { useMemo } from 'react';
import type { Address } from 'viem';
import { vaultAbi } from '@/config/generated';
import { adapterRangeAbi, priceBands, type AdapterPosition, type PriceBand } from './ranges';
import { USD_ANCHOR_SYMBOL } from './spot';
import { pick, useReads } from './useReads';

const PER_ADAPTER = 3;

export interface VaultRanges {
  /** Lowercase token address → its band in USDG; tokens without a live position are absent. */
  bands: ReadonlyMap<string, PriceBand>;
  isLoading: boolean;
}

export function useVaultRanges(
  chainId: number,
  vault: Address,
  tokens: readonly { address: Address; symbol: string; decimals: number }[],
): VaultRanges {
  const list = useReads([{ address: vault, abi: vaultAbi, functionName: 'adapters' } as const], { chainId, scope: vault });
  const adapters = pick<readonly Address[]>(list.data, 0) ?? [];

  const reads = useReads(
    adapters.flatMap((a) => [
      { address: a, abi: adapterRangeAbi, functionName: 'positionState' } as const,
      { address: a, abi: adapterRangeAbi, functionName: 'TOKEN0' } as const,
      { address: a, abi: adapterRangeAbi, functionName: 'TOKEN1' } as const,
    ]),
    { chainId, scope: vault, enabled: adapters.length > 0 },
  );

  const bands = useMemo(() => {
    const positions = adapters.flatMap((_, i): AdapterPosition[] => {
      const state = pick<readonly [bigint, number, number, bigint, number]>(reads.data, i * PER_ADAPTER);
      const token0 = pick<Address>(reads.data, i * PER_ADAPTER + 1);
      const token1 = pick<Address>(reads.data, i * PER_ADAPTER + 2);
      if (!state || !token0 || !token1) return [];
      return [{ token0, token1, id: state[0], tickLower: Number(state[1]), tickUpper: Number(state[2]) }];
    });
    return priceBands(tokens, USD_ANCHOR_SYMBOL, positions);
  }, [adapters.join(','), reads.data, tokens]);

  return { bands, isLoading: list.isLoading || reads.isLoading };
}
