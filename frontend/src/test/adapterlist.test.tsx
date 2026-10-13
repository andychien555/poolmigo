// @vitest-environment jsdom
/**
 * AdapterList lists POSITIONS, not registered slots: an adapter holding nothing — no live position,
 * no idle balance — is a slot the keeper has not used yet and must not render. A position() that
 * failed to report stays visible: it may hold funds. No chain is touched here; reports are built by
 * hand.
 */
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import type { Address } from 'viem';
import { AdapterList } from '@/components/live/AdapterList';
import type { AdapterReport, TokenMeta } from '@/chain/useVault';

const TOKENS: TokenMeta[] = [
  { address: '0x1111111111111111111111111111111111111111' as Address, symbol: 'USDG', name: 'USDG', decimals: 6 },
  { address: '0x2222222222222222222222222222222222222222' as Address, symbol: 'WETH', name: 'WETH', decimals: 18 },
];

/** keccak256("UNISWAP_V3") — dexLabel maps it to "uniswap-v3". */
const V3 = '0x3e1ba2b70880de8835e37b2821b3ca56e07c15ae583bf7dfa6888e3bd39bb5ca';

function report(address: Address, over: Partial<AdapterReport> = {}): AdapterReport {
  return {
    dex: V3,
    poolId: '0x0000000000000000000000000000000000000000',
    position: [0n, 0n],
    reportFailed: false,
    ...over,
    address,
  };
}

const FUNDED = '0xaaaa000000000000000000000000000000000001' as Address; // shortHex 0xaaaa…0001
const EMPTY_A = '0xbbbb000000000000000000000000000000000002' as Address; // shortHex 0xbbbb…0002
const EMPTY_B = '0xcccc000000000000000000000000000000000003' as Address; // shortHex 0xcccc…0003

afterEach(cleanup);

describe('AdapterList hides registered slots that hold nothing', () => {
  it('lists only the funded adapter and says how many slots are hidden', () => {
    render(<AdapterList adapters={[report(FUNDED, { position: [1n, 2n] }), report(EMPTY_A), report(EMPTY_B)]} tokens={TOKENS} />);
    expect(screen.getByText('Positions (1)')).toBeDefined();
    expect(screen.getByText('0xaaaa…0001')).toBeDefined();
    expect(screen.queryByText('0xbbbb…0002')).toBeNull();
    expect(screen.queryByText('0xcccc…0003')).toBeNull();
    expect(screen.getByText('Not shown: 2 registered slots holding no funds.')).toBeDefined();
  });

  it('keeps a position() that failed to report — it may hold funds', () => {
    render(<AdapterList adapters={[report(FUNDED, { reportFailed: true }), report(EMPTY_A)]} tokens={TOKENS} />);
    expect(screen.getByText('Positions (1)')).toBeDefined();
    expect(screen.getByText('0xaaaa…0001')).toBeDefined();
    expect(screen.getByText(/position\(\) did not report/)).toBeDefined();
    expect(screen.queryByText('0xbbbb…0002')).toBeNull();
  });

  it('explains an all-idle vault as slots, not positions', () => {
    render(<AdapterList adapters={[report(EMPTY_A), report(EMPTY_B)]} tokens={TOKENS} />);
    expect(screen.getByText('Positions (0)')).toBeDefined();
    expect(screen.getByText('No funded positions yet. 2 registered adapter slots idle — the keeper opens positions in them.')).toBeDefined();
  });

  it('keeps the no-adapters message when the registry is empty', () => {
    render(<AdapterList adapters={[]} tokens={TOKENS} />);
    expect(screen.getByText('No adapters registered. All basket tokens sit idle in the vault.')).toBeDefined();
  });
});
