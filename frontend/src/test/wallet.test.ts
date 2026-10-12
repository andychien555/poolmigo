/**
 * The wallet picker's decision logic: which wallets are offered, in what order, and which one a
 * returning visitor silently reconnects to. Pure functions on purpose — the providers themselves
 * are browser objects, but *what we do with the announcements* is where the bugs would live.
 */
import { describe, expect, it, vi } from 'vitest';
import type { EIP1193Provider } from 'viem';
import { SWITCH_ANSWER_TIMEOUT_MS } from '@/chain/switchChain';
import { buildWalletOptions, findDiscovered, resolveReconnect } from '@/wallet/options';
import { LEGACY_INJECTED_ID, WALLETCONNECT_ID, type DiscoveredProvider } from '@/wallet/types';
import {
  accountsFromSession,
  approvedChainIds,
  fixSwitchChainId,
  mergeConnectNamespaces,
  normalizeChainIdInput,
  requestSwitchThroughWallet,
  walletConnectAccounts,
  wrapWalletConnectProvider,
  type WalletConnectProviderLike,
} from '@/wallet/walletconnect';

const detail = (rdns: string, name: string): DiscoveredProvider => ({
  info: { uuid: `uuid-${rdns}`, rdns, name, icon: `data:image/svg+xml;base64,${rdns}` },
  provider: { rdns },
});

const metamask = detail('io.metamask', 'MetaMask');
const rabby = detail('io.rabby', 'Rabby Wallet');
const coinbase = detail('com.coinbase.wallet', 'Coinbase Wallet');

describe('buildWalletOptions — EIP-6963 discovery', () => {
  it('offers every announced wallet, with its own name and icon', () => {
    const options = buildWalletOptions({
      detected: [metamask, rabby, coinbase],
      hasLegacyInjected: true,
      walletConnectEnabled: false,
    });
    expect(options.map((o) => o.id)).toEqual(['com.coinbase.wallet', 'io.metamask', 'io.rabby']);
    expect(options.every((o) => o.kind === 'injected')).toBe(true);
    expect(options[1].name).toBe('MetaMask');
    expect(options[1].icon).toBe('data:image/svg+xml;base64,io.metamask');
  });

  it('sorts by name so a late announcement does not reshuffle the list', () => {
    const a = buildWalletOptions({ detected: [rabby, metamask], hasLegacyInjected: false, walletConnectEnabled: false });
    const b = buildWalletOptions({ detected: [metamask, rabby], hasLegacyInjected: false, walletConnectEnabled: false });
    expect(a.map((o) => o.name)).toEqual(b.map((o) => o.name));
    expect(a.map((o) => o.name)).toEqual(['MetaMask', 'Rabby Wallet']);
  });

  it('de-duplicates a wallet that announces twice', () => {
    const options = buildWalletOptions({
      detected: [metamask, detail('io.metamask', 'MetaMask (again)')],
      hasLegacyInjected: false,
      walletConnectEnabled: false,
    });
    expect(options).toHaveLength(1);
    expect(options[0].name).toBe('MetaMask');
  });

  it('ignores an announcement with no rdns', () => {
    const broken = { info: { uuid: 'x', name: 'Nameless', icon: '', rdns: '' }, provider: {} } as DiscoveredProvider;
    expect(buildWalletOptions({ detected: [broken], hasLegacyInjected: false, walletConnectEnabled: false })).toEqual([]);
  });
});

describe('buildWalletOptions — legacy window.ethereum fallback', () => {
  it('offers "Browser wallet" when nothing announced but window.ethereum exists', () => {
    const options = buildWalletOptions({ detected: [], hasLegacyInjected: true, walletConnectEnabled: false });
    expect(options).toEqual([{ id: LEGACY_INJECTED_ID, kind: 'injected', name: 'Browser wallet' }]);
  });

  it('does NOT add it alongside announced wallets — that would list the same wallet twice', () => {
    const options = buildWalletOptions({ detected: [metamask], hasLegacyInjected: true, walletConnectEnabled: false });
    expect(options.map((o) => o.id)).toEqual(['io.metamask']);
  });

  it('offers nothing at all in a browser with no wallet', () => {
    expect(buildWalletOptions({ detected: [], hasLegacyInjected: false, walletConnectEnabled: false })).toEqual([]);
  });
});

describe('buildWalletOptions — WalletConnect', () => {
  it('is hidden without a project id (never faked, never hardcoded)', () => {
    const options = buildWalletOptions({ detected: [metamask], hasLegacyInjected: false, walletConnectEnabled: false });
    expect(options.some((o) => o.kind === 'walletconnect')).toBe(false);
  });

  it('is appended last when a project id is configured', () => {
    const options = buildWalletOptions({ detected: [metamask], hasLegacyInjected: false, walletConnectEnabled: true });
    expect(options.map((o) => o.id)).toEqual(['io.metamask', WALLETCONNECT_ID]);
    expect(options[1].kind).toBe('walletconnect');
  });

  it('is the only option in a browser with no extension at all', () => {
    const options = buildWalletOptions({ detected: [], hasLegacyInjected: false, walletConnectEnabled: true });
    expect(options.map((o) => o.id)).toEqual([WALLETCONNECT_ID]);
  });
});

describe('resolveReconnect', () => {
  const options = buildWalletOptions({
    detected: [metamask, rabby],
    hasLegacyInjected: false,
    walletConnectEnabled: true,
  });

  it('resumes the wallet used last time', () => {
    expect(resolveReconnect(options, 'io.rabby')?.name).toBe('Rabby Wallet');
    expect(resolveReconnect(options, WALLETCONNECT_ID)?.kind).toBe('walletconnect');
  });

  it('resumes nothing on a first visit', () => {
    expect(resolveReconnect(options, null)).toBeUndefined();
    expect(resolveReconnect(options, '')).toBeUndefined();
  });

  it('resumes nothing when that wallet is no longer installed', () => {
    expect(resolveReconnect(options, 'app.phantom')).toBeUndefined();
  });
});

describe('findDiscovered', () => {
  it('maps an option id back to the announced provider', () => {
    expect(findDiscovered([metamask, rabby], 'io.rabby')).toBe(rabby);
    expect(findDiscovered([metamask, rabby], LEGACY_INJECTED_ID)).toBeUndefined();
  });
});

describe('wrapWalletConnectProvider — session discipline', () => {
  const makeFake = (withSession: boolean) => {
    const state: { session?: unknown } = { session: withSession ? { topic: 't' } : undefined };
    const calls: string[] = [];
    const provider: WalletConnectProviderLike = {
      get session() {
        return state.session;
      },
      get accounts() {
        return state.session ? ['0xAbC123'] : [];
      },
      async connect() {
        calls.push('connect');
        state.session = { topic: 't' };
      },
      async request(args) {
        calls.push(`request:${args.method}`);
        return [`passthrough:${args.method}`];
      },
    };
    return { provider, calls };
  };

  it('opens the pairing (connect) on eth_requestAccounts when there is no session', async () => {
    const { provider, calls } = makeFake(false);
    const wrapped = wrapWalletConnectProvider(provider);
    const accounts = await wrapped.request({ method: 'eth_requestAccounts' });
    expect(calls).toEqual(['connect']);
    expect(accounts).toEqual(['0xAbC123']);
  });

  it('skips connect when a session already exists', async () => {
    const { provider, calls } = makeFake(true);
    const wrapped = wrapWalletConnectProvider(provider);
    const accounts = await wrapped.request({ method: 'eth_requestAccounts' });
    expect(calls).toEqual([]);
    expect(accounts).toEqual(['0xAbC123']);
  });

  it('answers eth_accounts quietly with [] until a session exists — like an injected wallet', async () => {
    const { provider, calls } = makeFake(false);
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'eth_accounts' })).toEqual([]);
    expect(calls).toEqual([]);
  });

  it('passes every other request straight through', async () => {
    const { provider, calls } = makeFake(true);
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'eth_chainId' })).toEqual(['passthrough:eth_chainId']);
    expect(calls).toEqual(['request:eth_chainId']);
  });
});

/**
 * v2's `provider.accounts` filters the session down to the PERSISTED chain — when that chain no
 * longer lines up with the session's accounts it reads empty while the session holds a real
 * address. Returned visitors then got "WalletConnect returned no account."; accounts must come
 * from the session itself.
 */
describe('wrapWalletConnectProvider — chain-mismatched sessions', () => {
  const caipSession = (accounts: string[]) => ({
    topic: 't',
    namespaces: {
      eip155: {
        accounts,
        methods: ['personal_sign'],
        events: ['accountsChanged'],
        chains: ['eip155:46630'],
      },
    },
  });

  it('reads the address from the session even when provider.accounts is empty (persisted chain mismatch)', async () => {
    const calls: string[] = [];
    const provider: WalletConnectProviderLike = {
      session: caipSession(['eip155:46630:0xAbC123']),
      accounts: [],
      async connect() {
        calls.push('connect');
      },
      async request() {
        return ['passthrough'];
      },
    };
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'eth_requestAccounts' })).toEqual(['0xAbC123']);
    expect(calls).toEqual([]); // the session is fine — no re-pair
    expect(await wrapped.request({ method: 'eth_accounts' })).toEqual(['0xAbC123']);
  });

  it('re-pairs once when an existing session carries no usable account', async () => {
    let session: unknown = { topic: 'broken', namespaces: { eip155: { accounts: [] } } };
    const calls: string[] = [];
    const provider: WalletConnectProviderLike = {
      get session() {
        return session;
      },
      accounts: [],
      async disconnect() {
        calls.push('disconnect');
      },
      async connect() {
        calls.push('connect');
        session = caipSession(['eip155:46630:0xDeF456']);
      },
      async request() {
        return [];
      },
    };
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'eth_requestAccounts' })).toEqual(['0xDeF456']);
    expect(calls).toEqual(['disconnect', 'connect']);
  });

  it('fails loudly when the pairing was never completed (instead of returning [])', async () => {
    const provider: WalletConnectProviderLike = {
      session: undefined,
      accounts: [],
      async connect() {
        /* the visitor closed the modal — no session appears */
      },
      async request() {
        return [];
      },
    };
    const wrapped = wrapWalletConnectProvider(provider);
    await expect(wrapped.request({ method: 'eth_requestAccounts' })).rejects.toThrow(/not completed/i);
  });

  it('de-duplicates the same address across inline and nested namespace layouts', async () => {
    const provider: WalletConnectProviderLike = {
      session: {
        topic: 't',
        namespaces: {
          eip155: { accounts: ['eip155:46630:0xAbC123'] },
          'eip155:4663': { accounts: ['eip155:4663:0xabc123', 'eip155:4663:0xDeF456'] },
        },
      },
      accounts: [],
      async connect() {},
      async request() {
        return [];
      },
    };
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'eth_requestAccounts' })).toEqual(['0xAbC123', '0xDeF456']);
    expect(accountsFromSession(provider)).toEqual(['0xAbC123', '0xDeF456']);
  });

  it('walletConnectAccounts prefers the session — the silent reconnect must not read []', () => {
    const provider = {
      session: caipSession(['eip155:46630:0xAbC123']),
      accounts: [] as readonly string[],
    } as unknown as EIP1193Provider;
    expect(walletConnectAccounts(provider)).toEqual(['0xAbC123']);
  });
});

describe('mergeConnectNamespaces — the default chain must survive the proposal (EP/UP 2.25)', () => {
  // The shape EthereumProvider.connect() actually hands signer.connect (captured from v2.25.0):
  // the default chain under `namespaces`, everything else under `optionalNamespaces`. The
  // universal-provider merge used to drop the first, so wallets never saw eip155:46630.
  const epShape = () => ({
    namespaces: {
      eip155: {
        chains: ['eip155:46630'],
        methods: ['eth_sendTransaction', 'personal_sign'],
        events: ['chainChanged'],
        rpcMap: { '46630': 'http://127.0.0.1:8547' },
      },
    },
    optionalNamespaces: {
      eip155: {
        chains: ['eip155:4663'],
        methods: ['eth_sign', 'wallet_switchEthereumChain'],
        events: ['accountsChanged'],
        rpcMap: { '4663': 'https://robinhood.drpc.org', '46630': 'http://127.0.0.1:8547' },
      },
    },
    pairingTopic: 'topic-1',
  });

  it('merges both inputs into one optionalNamespaces — the default chain no longer vanishes', () => {
    const out = mergeConnectNamespaces(epShape());
    expect(out.namespaces).toBeUndefined();
    expect(out.requiredNamespaces).toBeUndefined();
    expect(out.optionalNamespaces?.eip155?.chains).toEqual(['eip155:46630', 'eip155:4663']);
    expect(out.pairingTopic).toBe('topic-1');
  });

  it('unions methods/events and keeps every rpc entry', () => {
    const ns = mergeConnectNamespaces(epShape()).optionalNamespaces?.eip155;
    expect(ns?.methods).toEqual([
      'eth_sendTransaction',
      'personal_sign',
      'eth_sign',
      'wallet_switchEthereumChain',
    ]);
    expect(ns?.events).toEqual(['chainChanged', 'accountsChanged']);
    expect(ns?.rpcMap).toEqual({ '46630': 'http://127.0.0.1:8547', '4663': 'https://robinhood.drpc.org' });
  });

  it('de-duplicates a chain that appears in both inputs', () => {
    const out = mergeConnectNamespaces({
      namespaces: { eip155: { chains: ['eip155:1'] } },
      optionalNamespaces: { eip155: { chains: ['eip155:1', 'eip155:2'] } },
    });
    expect(out.optionalNamespaces?.eip155?.chains).toEqual(['eip155:1', 'eip155:2']);
  });

  it('keeps a required-only set — as optional, never as required', () => {
    const out = mergeConnectNamespaces({ namespaces: { eip155: { chains: ['eip155:46630'] } } });
    expect(out.optionalNamespaces?.eip155?.chains).toEqual(['eip155:46630']);
    expect(out.requiredNamespaces).toBeUndefined();
  });

  it('passes an argument with no namespaces through untouched', () => {
    expect(mergeConnectNamespaces({ pairingTopic: 'x' })).toEqual({ pairingTopic: 'x' });
  });

  it('leaves unrelated namespaces alone while merging eip155', () => {
    const out = mergeConnectNamespaces({
      namespaces: { solana: { chains: ['solana:abc'] } },
      optionalNamespaces: { eip155: { chains: ['eip155:4663'] } },
    });
    expect(out.optionalNamespaces?.solana?.chains).toEqual(['solana:abc']);
    expect(out.optionalNamespaces?.eip155?.chains).toEqual(['eip155:4663']);
  });
});

describe('chain-id normalisation — upstream v2.25 emits NaN and un-prefixed hex', () => {
  it('normalises every shape EP produces into eip155:<decimal>', () => {
    expect(normalizeChainIdInput('eip155:46630')).toBe('eip155:46630');
    expect(normalizeChainIdInput('eip155:0xb626')).toBe('eip155:46630');
    expect(normalizeChainIdInput('eip155:eip155:46630')).toBe('eip155:46630'); // double prefix
    expect(normalizeChainIdInput('eip155:1')).toBe('eip155:1');
  });

  it('refuses values that are not chain ids — NaN must not corrupt the provider', () => {
    expect(normalizeChainIdInput('eip155:NaN')).toBeUndefined();
    expect(normalizeChainIdInput('eip155:eip155:NaN')).toBeUndefined();
    expect(normalizeChainIdInput('eip155:')).toBeUndefined();
    expect(normalizeChainIdInput(46630)).toBeUndefined();
    expect(normalizeChainIdInput(undefined)).toBeUndefined();
  });

  it('fixes the echo-switch chain id (bare hex from toString(16)) and drops junk', () => {
    expect(fixSwitchChainId('b626')).toBe('0xb626');
    expect(fixSwitchChainId('0xb626')).toBe('0xb626');
    expect(fixSwitchChainId('1')).toBe('0x1');
    expect(fixSwitchChainId('NaN')).toBeUndefined();
    expect(fixSwitchChainId('0xNaN')).toBeUndefined();
    expect(fixSwitchChainId('')).toBeUndefined();
  });
});

/**
 * UP answers a switch to a chain in the session purely locally (`setDefaultChain`) — the wallet
 * never hears about it, so a wallet that is on another chain stays there and "Switch" looks dead
 * (reproduced live against the mock wallet: two in-session switches, zero wallet-side traffic).
 * The wrapper now asks the wallet through the session first, then still runs the normal request
 * for the SDK's own bookkeeping.
 */
describe('wallet_switchEthereumChain reaches the wallet itself', () => {
  const makeFake = (opts: { approved?: string[]; fail?: unknown; neverAnswer?: boolean } = {}) => {
    const chains = opts.approved ?? ['eip155:1', 'eip155:46630', 'eip155:4663'];
    const calls: { client: unknown[]; provider: unknown[] } = { client: [], provider: [] };
    const provider: WalletConnectProviderLike = {
      session: { topic: 'topic-1', namespaces: { eip155: { chains } } },
      signer: {
        namespace: { chains },
        client: {
          async request(args: unknown) {
            calls.client.push(args);
            if (opts.neverAnswer) return await new Promise<never>(() => {});
            if (opts.fail !== undefined) throw opts.fail;
            return null;
          },
        },
      },
      async connect() {},
      async request(args: { method: string; params?: unknown }) {
        calls.provider.push(args);
        return null;
      },
    };
    return { provider, calls };
  };

  it('sends the switch through the session, then lets the SDK bookkeeping run', async () => {
    const { provider, calls } = makeFake();
    const wrapped = wrapWalletConnectProvider(provider);
    await wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] });
    expect(calls.client).toEqual([
      {
        topic: 'topic-1',
        request: { method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] },
        chainId: 'eip155:1',
      },
    ]);
    expect(calls.provider).toEqual([{ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] }]);
  });

  it('does not ask the wallet for a chain the session does not cover', async () => {
    const { provider, calls } = makeFake();
    const wrapped = wrapWalletConnectProvider(provider);
    await wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x99' }] });
    expect(calls.client).toEqual([]);
    expect(calls.provider).toEqual([{ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x99' }] }]);
  });

  it('a rejection in the wallet reaches the user and skips the local switch', async () => {
    const { provider, calls } = makeFake({ fail: { code: 4001, message: 'User rejected the request.' } });
    const wrapped = wrapWalletConnectProvider(provider);
    await expect(
      wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] }),
    ).rejects.toMatchObject({ code: 4001 });
    expect(calls.provider).toEqual([]);
  });

  it('any other wallet failure falls back to the SDK path', async () => {
    const { provider, calls } = makeFake({ fail: new Error('boom') });
    const wrapped = wrapWalletConnectProvider(provider);
    await wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] });
    expect(calls.provider).toEqual([{ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] }]);
  });

  it('gives up with a clear timeout when the wallet never answers (no infinite pinning)', async () => {
    vi.useFakeTimers();
    try {
      const { provider, calls } = makeFake({ neverAnswer: true });
      const wrapped = wrapWalletConnectProvider(provider);
      const pending = wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0xb626' }] });
      const outcome = expect(pending).rejects.toMatchObject({ name: 'WalletSwitchTimeoutError' });
      await vi.advanceTimersByTimeAsync(SWITCH_ANSWER_TIMEOUT_MS);
      await outcome;
      expect(calls.client).toHaveLength(1);
      expect(calls.provider).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('drops junk chain ids without touching anything', async () => {
    const { provider, calls } = makeFake();
    const wrapped = wrapWalletConnectProvider(provider);
    expect(await wrapped.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: 'NaN' }] })).toBeNull();
    expect(calls.client).toEqual([]);
    expect(calls.provider).toEqual([]);
  });

  it('approvedChainIds: UP namespace first, session fallback, empty when neither', () => {
    expect(approvedChainIds(makeFake().provider)).toEqual(['eip155:1', 'eip155:46630', 'eip155:4663']);
    const sessionOnly: WalletConnectProviderLike = {
      session: { topic: 't', namespaces: { eip155: { chains: ['eip155:4663'] } } },
      connect: async () => {},
      request: async () => null,
    };
    expect(approvedChainIds(sessionOnly)).toEqual(['eip155:4663']);
    expect(approvedChainIds({ connect: async () => {}, request: async () => null })).toEqual([]);
  });

  it('requestSwitchThroughWallet resolves quietly without a session', async () => {
    await expect(
      requestSwitchThroughWallet({ connect: async () => {}, request: async () => null }, '0xb626'),
    ).resolves.toBeUndefined();
  });
});
