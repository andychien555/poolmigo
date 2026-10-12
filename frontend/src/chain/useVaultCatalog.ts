/**
 * The real vault catalogue: every registry deployment (chain × vault), read live over RPC — what the
 * homepage's vault table is made of. No invented numbers: basket tokens, in-kind totals, receipt
 * supply, paused state and the connected wallet's own balances; a figure the chain cannot provide is
 * simply absent (the caller renders "—"), never synthesised.
 *
 * One `useReads` round per chain (RPC clients are per-chain), so the reads stay cache-keyed by
 * chainId + scope and two components asking for the same chain share one request. The vault list
 * round covers `tokens / totalTokens / totalSupply / paused / decimals / balanceOf`; a second round
 * fetches the basket tokens' symbols + decimals; a third the wallet's balance of each basket token
 * (only with an account).
 */
import { useMemo } from 'react';
import type { Address } from 'viem';
import { erc20Abi } from 'viem';
import { DEPLOYMENTS, vaultAbi } from '@/config/generated';
import type { ChainDeployment, VaultEntry } from './chains';
import { shortHex } from './amounts';
import { pick, useReads } from './useReads';

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address;

/** Calls per vault in the first round: tokens, totalTokens, totalSupply, paused, decimals, balanceOf. */
const STRIDE = 6;

export interface CatalogToken {
  address: Address;
  /** On-chain symbol; the short address until the read lands (or forever, if it never does). */
  symbol: string;
  decimals: number;
  /** The vault's total for this token (idle + everything the adapters hold), from `totalTokens`. */
  total: bigint;
  /** The connected wallet's own balance, when an account was given and the read landed. */
  balance: bigint | undefined;
}

export interface CatalogVault {
  chainId: number;
  chainName: string;
  isLocal: boolean;
  entry: VaultEntry;
  address: Address;
  /** The receipt token's decimals (18 until read). */
  decimals: number;
  tokens: CatalogToken[];
  supply: bigint | undefined;
  paused: boolean | undefined;
  /** The wallet's receipt balance (zero included); undefined when no account / the read failed. */
  receiptBalance: bigint | undefined;
  /** The first round landed (basket addresses are known). */
  ready: boolean;
  /** The chain could not be reached at all — every read in the first round failed. */
  failed: boolean;
  isLoading: boolean;
}

/** Every registry vault, live. Pass the connected account (or undefined) to also read its balances. */
export function useVaultCatalog(account?: Address): CatalogVault[] {
  // The registry is a build-time constant (a new chain or vault means a new build + sync), so the
  // hook order here is fixed for the life of a mount: the deployed-chain list never changes length
  // between renders. One catalogue hook per chain keeps each `useReads` on a single chainId.
  const perChain = DEPLOYMENTS.map((d) => useChainCatalog(d, account));
  return useMemo(() => perChain.flat(), perChain);
}

function useChainCatalog(deployment: ChainDeployment, account: Address | undefined): CatalogVault[] {
  const vaults = deployment.vaults;

  const round1 = useReads(
    vaults.flatMap((v) => [
      { address: v.vault, abi: vaultAbi, functionName: 'tokens' } as const,
      { address: v.vault, abi: vaultAbi, functionName: 'totalTokens' } as const,
      { address: v.vault, abi: vaultAbi, functionName: 'totalSupply' } as const,
      { address: v.vault, abi: vaultAbi, functionName: 'paused' } as const,
      { address: v.vault, abi: vaultAbi, functionName: 'decimals' } as const,
      { address: v.vault, abi: vaultAbi, functionName: 'balanceOf', args: [account ?? ZERO_ADDRESS] } as const,
    ]),
    { chainId: deployment.chainId, scope: 'catalog' },
  );

  const basketAddrs = vaults.map((_, i) => pick<readonly Address[]>(round1.data, i * STRIDE) ?? []);
  const flatTokens = basketAddrs.flat();

  // Symbols + decimals of every basket token, in one round (two calls per token).
  const round2 = useReads(
    flatTokens.flatMap((t) => [
      { address: t, abi: erc20Abi, functionName: 'symbol' } as const,
      { address: t, abi: erc20Abi, functionName: 'decimals' } as const,
    ]),
    { chainId: deployment.chainId, scope: 'catalog', enabled: flatTokens.length > 0 },
  );

  // The wallet's own balance of each basket token — only asked for with an account.
  const round3 = useReads(
    account
      ? flatTokens.map((t) => ({ address: t, abi: erc20Abi, functionName: 'balanceOf', args: [account] }) as const)
      : [],
    { chainId: deployment.chainId, scope: 'catalog', enabled: Boolean(account) && flatTokens.length > 0 },
  );

  const failed = Boolean(round1.error);
  let offset = 0;
  return vaults.map((entry, i): CatalogVault => {
    const base = i * STRIDE;
    const addrs = basketAddrs[i];
    const first = offset;
    offset += addrs.length;

    const totalsRead = pick<readonly [readonly Address[], readonly bigint[]]>(round1.data, base + 1);
    const totals = addrs.map((t) => {
      if (!totalsRead) return 0n;
      const [toks, amounts] = totalsRead;
      const idx = toks.findIndex((x) => x.toLowerCase() === t.toLowerCase());
      return idx === -1 ? 0n : (amounts[idx] ?? 0n);
    });

    const tokens: CatalogToken[] = addrs.map((t, j) => ({
      address: t,
      symbol: pick<string>(round2.data, (first + j) * 2) ?? shortHex(t),
      decimals: Number(pick<number>(round2.data, (first + j) * 2 + 1) ?? 18),
      total: totals[j] ?? 0n,
      balance: account ? pick<bigint>(round3.data, first + j) : undefined,
    }));

    return {
      chainId: deployment.chainId,
      chainName: deployment.name,
      isLocal: deployment.local === true,
      entry,
      address: entry.vault,
      decimals: Number(pick<number>(round1.data, base + 4) ?? 18),
      tokens,
      supply: pick<bigint>(round1.data, base + 2),
      paused: pick<boolean>(round1.data, base + 3),
      receiptBalance: account ? pick<bigint>(round1.data, base + 5) : undefined,
      ready: pick<readonly Address[]>(round1.data, base) !== undefined,
      failed,
      isLoading: round1.isLoading || (flatTokens.length > 0 && round2.isLoading),
    };
  });
}
