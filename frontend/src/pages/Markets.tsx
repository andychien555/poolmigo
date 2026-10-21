/**
 * The home page: the selected chain's vaults, read live from the chain (src/chain/useLiveVaults.ts).
 * The table follows the header's chain selector (useTargetChain): switch chain, see that chain's
 * vaults. TVL is the basket's `totalTokens()` at the live reference-pool spot (USDG at its $1 peg —
 * display only); spot NAV is that TVL over the receipt supply; the fee is `performanceFeeBps`. APR is
 * the original design's fee APR — trading fees over the last 7 days ÷ the mean TVL, annualised — from
 * the NAV-history collector (src/chain/feeApy.ts; the same fetch the vault page's chart reads); "—"
 * until 7 days are covered. No volume column: the chain cannot answer it (docs/LIVE-DATA.md). Each
 * row's range meter puts the live spot between the adapters' on-chain range (src/chain/ranges.ts). "Deposit" opens the
 * vault's page; `?deposit=<vault id>` opens the deposit card over this page, as the original did.
 */
import { useMemo, useState, type ReactNode } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useWallet } from '@/wallet/context';
import { DEPLOYMENTS } from '@/chain/chains';
import { useTargetChain } from '@/chain/useTargetChain';
import { basketName, feeLabel, holdingUsd, resolveVaultRouteId, tokenUsdPrices, vaultRouteId } from '@/chain/liveVaults';
import { useLiveVaults, type LiveVaultRow } from '@/chain/useLiveVaults';
import type { ChainSpots } from '@/chain/useSpotPrices';
import { useVaultRanges } from '@/chain/useVaultRanges';
import { FEE_APR_WINDOW_DAYS, feeApyPct, fmtFeeApr } from '@/chain/feeApy';
import { useNavHistoryRows } from '@/chain/useNavHistory';
import { cx, fmtPct, fmtPrice, fmtUsd } from '@/lib/format';
import { Stat, StatRow } from '@/components/ui/Stat';
import { TokenGroup } from '@/components/ui/TokenIcon';
import { Button } from '@/components/ui/Button';
import { Arrow } from '@/components/ui/Arrow';
import { Spinner } from '@/components/ui/Spinner';
import { LiveBadge } from '@/components/ui/DataBadge';
import { RangeMeter } from '@/components/vault/RangeMeter';
import { rangePairsFor } from '@/components/vault/rangePairs';
import { DepositModal } from '@/components/deposit/DepositModal';
import { Welcome } from '@/components/layout/Welcome';
import { SkyScene } from '@/components/brand/SkyScene';

type SortKey = 'apr' | 'tvl' | 'nav';

export function Markets() {
  const { address } = useWallet();
  const { rows: all, spotsFor } = useLiveVaults(address ?? undefined);
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const depositRef = resolveVaultRouteId(params.get('deposit') ?? undefined, DEPLOYMENTS);
  const depositRow = depositRef.kind === 'found' ? all.find((r) => r.id === vaultRouteId(depositRef.ref.chainId, depositRef.ref.key)) ?? null : null;
  const [q, setQ] = useState('');
  const { selectedChainId } = useTargetChain();
  const chain = String(selectedChainId);
  const [sort, setSort] = useState<{ key: SortKey; dir: 'asc' | 'desc' }>({ key: 'tvl', dir: 'desc' });
  const toggleSort = (key: SortKey) => setSort((s) => (s.key === key ? { key, dir: s.dir === 'desc' ? 'asc' : 'desc' } : { key, dir: 'desc' }));

  const { rows: history } = useNavHistoryRows();
  const aprOf = useMemo(() => {
    const m = new Map<string, number | undefined>();
    for (const r of all) m.set(r.id, feeApyPct(history, r.v.entry.key, FEE_APR_WINDOW_DAYS, r.v.chainId));
    return m;
  }, [all, history]);

  const rows = useMemo(() => {
    const val = (r: LiveVaultRow) => (sort.key === 'apr' ? aprOf.get(r.id) : sort.key === 'tvl' ? r.valuation.usd : r.nav) ?? -1;
    const needle = q.toLowerCase().replace(/\s/g, '');
    return all
      .filter((r) => String(r.v.chainId) === chain)
      .filter((r) => `${nameOf(r)} ${r.v.entry.receipt.symbol} ${r.v.chainName}`.toLowerCase().replace(/\s/g, '').includes(needle))
      .sort((a, b) => (sort.dir === 'desc' ? val(b) - val(a) : val(a) - val(b)));
  }, [all, q, chain, sort, aprOf]);

  const priced = rows.filter((r) => r.valuation.usd !== undefined);
  const totalTvl = priced.reduce((s, r) => s + (r.valuation.usd ?? 0), 0);
  const mine = rows
    .map((r) => holdingUsd(r.v.receiptBalance, r.v.supply, r.valuation.usd))
    .filter((x): x is number => x !== undefined && x > 0);
  const showMine = Boolean(address) && mine.length > 0;
  const chainName = DEPLOYMENTS.find((d) => String(d.chainId) === chain)?.name;

  const deposit = (r: LiveVaultRow) => navigate(`/vault/${r.id}`);

  return (
    <div>
      {/* The sky: who you are here and what you hold, over the scene */}
      <section className={cx('relative overflow-hidden border-b border-stroke-strong', showMine ? 'sm:h-[clamp(360px,44vh,410px)]' : 'sm:h-[clamp(410px,54vh,500px)]')}>
        {/* On phones the scene is a band across the top; from sm up it fills the section */}
        <SkyScene className="absolute inset-x-0 top-0 h-[260px] w-full sm:h-full" />
        <div className="sky-shade absolute inset-x-0 top-0 z-[2] h-[260px] pointer-events-none sm:h-full" />
        <div className="wrap relative z-[4] grid justify-items-start gap-[18px] pt-[190px] sm:pt-[clamp(32px,6vh,56px)]">
          {showMine ? (
            <>
              <p className="eyebrow !text-weak">Your deposits</p>
              <div className="display text-[clamp(48px,6vw,80px)] leading-none tracking-[-0.02em]">{fmtUsd(mine.reduce((s, x) => s + x, 0), { compact: false })}</div>
            </>
          ) : (
            <Welcome />
          )}
        </div>
        <div className="wrap relative z-[4] py-6 sm:absolute sm:inset-x-0 sm:bottom-0">
          <StatRow cols={2} packed rule={false}>
            <Stat label="Total TVL" value={priced.length > 0 ? fmtUsd(totalTvl) : '—'} sub={priced.length < rows.length && priced.length > 0 ? `${priced.length} of ${rows.length} vaults priced` : undefined} />
            <Stat label="Vaults live" value={String(rows.length)} sub={chainName ?? DEPLOYMENTS.map((d) => d.name).join(' · ')} />
          </StatRow>
        </div>
      </section>

      {/* The plaza: every vault as an instrument */}
      <div className="wrap pt-[52px] pb-[120px]">
        <div className="mb-[22px] flex flex-wrap items-end justify-between gap-x-7 gap-y-[18px]">
          <div className="flex items-center gap-3">
            <h1 className="title text-[clamp(32px,3.6vw,46px)]">Vaults</h1>
            <LiveBadge />
          </div>
          <div className="flex w-full flex-wrap items-center gap-x-[22px] gap-y-3.5 sm:w-auto">
            <label className="flex h-10 w-full items-center gap-2 rounded border border-stroke-strong px-3 text-weaker focus-within:border-stroke-strongest sm:w-[220px]">
              <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 shrink-0" fill="none" aria-hidden>
                <circle cx="7" cy="7" r="4.5" stroke="currentColor" strokeWidth="1.5" />
                <path d="M10.5 10.5L14 14" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
              </svg>
              <input
                value={q}
                onChange={(e) => setQ(e.target.value)}
                placeholder="Search vaults"
                aria-label="Search vaults"
                className="min-w-0 flex-1 bg-transparent text-sm text-strong outline-none placeholder:text-weaker focus-visible:outline-none"
              />
            </label>
          </div>
        </div>

        <div className={cx('eyebrow hidden items-center border-b border-stroke-strong px-4 pb-2.5 lg:grid', COLS)}>
          <span>Vault</span>
          <span>Basket at spot</span>
          <span className="justify-self-end">Fee</span>
          <span className="justify-self-end"><SortHead label="APR" active={sort.key === 'apr'} dir={sort.dir} onClick={() => toggleSort('apr')} /></span>
          <span className="justify-self-end"><SortHead label="TVL" active={sort.key === 'tvl'} dir={sort.dir} onClick={() => toggleSort('tvl')} /></span>
          <span className="justify-self-end"><SortHead label="NAV" active={sort.key === 'nav'} dir={sort.dir} onClick={() => toggleSort('nav')} /></span>
          <span />
        </div>
        <div className="eyebrow flex justify-end gap-[18px] px-3 lg:hidden">
          <SortHead label="APR" active={sort.key === 'apr'} dir={sort.dir} onClick={() => toggleSort('apr')} />
          <SortHead label="TVL" active={sort.key === 'tvl'} dir={sort.dir} onClick={() => toggleSort('tvl')} />
          <SortHead label="NAV" active={sort.key === 'nav'} dir={sort.dir} onClick={() => toggleSort('nav')} />
        </div>
        <ul>
          {rows.map((r) => (
            <VaultRow key={r.id} row={r} apr={aprOf.get(r.id)} spots={spotsFor(r.v.chainId)} onDeposit={() => deposit(r)} />
          ))}
          {rows.length === 0 && (
            <li className="border-b border-stroke-weak py-12 text-center text-weaker">No vaults match{q ? ` "${q}"` : ''}.</li>
          )}
        </ul>
        <p className="mt-4 text-2xs text-weaker leading-relaxed max-w-3xl">
          Read live from each vault. USD is display only: USDG at its $1 peg, other tokens at the live spot of their reference pool
          (no oracle). NAV = TVL ÷ receipt supply. APR = trading fees over the last 7 days ÷ the average TVL, annualised, from
          hourly off-chain snapshots; — until 7 days of history exist (no history, no figure). No volume: the chain has no
          history to compute it from. Range
          meters: the price is the live spot; bounds = the adapters' on-chain ranges (their positions' tick bounds in USDG).
        </p>
      </div>
      <DepositModal row={depositRow} spots={depositRow ? spotsFor(depositRow.v.chainId) : undefined} onClose={() => setParams({})} />
    </div>
  );
}

function nameOf(r: LiveVaultRow): string {
  return basketName(r.v.ready ? r.v.tokens.map((t) => t.symbol) : [], r.v.entry.label);
}

// Columns: vault, its basket, fee, APR, TVL, NAV, action
// A row only fits from lg; below that it stacks as on a phone.
const COLS =
  'lg:grid-cols-[minmax(220px,1.15fr)_minmax(180px,1.7fr)_64px_72px_92px_84px_76px] lg:gap-x-4 xl:grid-cols-[minmax(190px,1.15fr)_minmax(200px,1.7fr)_80px_88px_104px_96px_104px] xl:gap-x-6';

function VaultRow({ row: r, apr, spots, onDeposit }: { row: LiveVaultRow; apr: number | undefined; spots: ChainSpots; onDeposit: () => void }) {
  const navigate = useNavigate();
  const { v, valuation } = r;
  const label = 'mr-1.5 text-xs font-normal text-weaker lg:hidden';
  const symbols = v.tokens.map((t) => t.symbol);
  const loading = !v.failed && (!v.ready || (r.spotsLoading && valuation.usd === undefined));
  const usdCell = (x: number | undefined, fmt: (n: number) => string) =>
    v.failed ? <span className="text-weaker">—</span> : loading ? <Spinner className="h-3.5 w-3.5 text-weaker inline-block" /> : x === undefined ? <span className="text-weaker">—</span> : fmt(x);

  return (
    <li
      data-vault={r.id}
      className={cx(
        'grid cursor-pointer grid-cols-[minmax(0,1fr)_auto] items-center gap-x-6 gap-y-2 border-b border-stroke-weak px-3 py-4 lg:px-4 transition-colors duration-300 ease-dusk hover:bg-strong/[0.035]',
        "[grid-template-areas:'pair_fee''meter_meter''apr_act''tvl_act''nav_act'] lg:[grid-template-areas:none]",
        COLS,
      )}
      onClick={() => navigate(`/vault/${r.id}`)}
    >
      <div className="flex min-w-0 items-start gap-3.5 [grid-area:pair] [--name:calc(23px*1.1)] lg:[grid-area:auto]">
        {symbols.length > 0 && <span className="flex shrink-0 mt-[calc((var(--name)-26px)/2)]"><TokenGroup symbols={symbols} size={26} /></span>}
        <div className="min-w-0">
          <div className="font-serif text-[23px] font-normal leading-[var(--name)] text-strong lg:truncate" title={v.entry.label}>{nameOf(r)}</div>
          <div className="mt-1 text-2xs text-weaker num">
            {v.entry.receipt.symbol} · {v.chainName}
            {v.paused && <span className="text-warning"> · paused</span>}
            {v.failed && <span className="text-warning"> · chain not reachable</span>}
          </div>
        </div>
      </div>
      <div className="grid min-w-0 gap-1 [grid-area:meter] lg:[grid-area:auto]">
        <Composition row={r} />
        <Range row={r} spots={spots} />
      </div>
      <div className="num text-md text-weak justify-self-end whitespace-nowrap [grid-area:fee] lg:[grid-area:auto]"><span className={label}>Fee</span>{feeLabel(v.performanceFeeBps)}</div>
      <div className="num text-md text-weak [grid-area:apr] lg:justify-self-end lg:[grid-area:auto]" title="Trading fees, 7-day average, annualised"><span className={label}>APR</span>{apr === undefined ? <span className="text-weaker">—</span> : fmtFeeApr(apr)}</div>
      <div className="display num text-xl text-strong [grid-area:tvl] lg:justify-self-end lg:[grid-area:auto]"><span className={label}>TVL</span>{usdCell(valuation.usd, (n) => fmtUsd(n, { cents: n < 10_000 }))}</div>
      <div className="num text-md text-weak [grid-area:nav] lg:justify-self-end lg:[grid-area:auto]"><span className={label}>NAV</span>{usdCell(r.nav, fmtPrice)}</div>
      <div className="justify-self-end self-center [grid-area:act] lg:[grid-area:auto]">
        <Button size="sm" disabled={v.paused === true} onClick={(e) => { e.stopPropagation(); onDeposit(); }}>
          {v.paused ? 'Paused' : 'Deposit'}
        </Button>
      </div>
    </li>
  );
}

/** The first non-USDG token with a live position: its spot between the adapters' on-chain range. */
function Range({ row: { v }, spots }: { row: LiveVaultRow; spots: ChainSpots }) {
  const { bands } = useVaultRanges(v.chainId, v.address, v.tokens);
  const pair = rangePairsFor(v.tokens, tokenUsdPrices(v.tokens, spots.spots), bands)[0];
  if (!pair) return null;
  return (
    <div title={`${pair.base} in ${pair.quote} — live price, on-chain range`}>
      <RangeMeter price={pair.price} lower={pair.lower} upper={pair.upper} />
    </div>
  );
}

/** Each token's share of the basket's spot value, as one stacked bar with the shares under it. */
function Composition({ row: { v, valuation } }: { row: LiveVaultRow }) {
  if (!v.ready) return <span className="text-xs text-weaker">{v.failed ? '—' : 'reading basket…'}</span>;
  const shares = valuation.legs.map((l) => l.share);
  return (
    <div className="grid gap-1.5">
      <div className="flex h-1.5 w-full overflow-hidden rounded-full bg-fill-track" aria-hidden>
        {shares.map((s, i) => (
          <span key={i} className={cx('h-full', i % 2 === 0 ? 'bg-fill-primary' : 'bg-strong/40')} style={{ width: `${(s ?? 0) * 100}%` }} />
        ))}
      </div>
      <div className="flex flex-wrap gap-x-3 text-2xs text-weaker num">
        {v.tokens.map((t, i) => (
          <span key={t.address}>{t.symbol} {shares[i] === undefined ? '—' : fmtPct(shares[i]!)}</span>
        ))}
      </div>
    </div>
  );
}

/** A sortable column label. */
function SortHead({ label, active, dir, onClick }: { label: string; active: boolean; dir: 'asc' | 'desc'; onClick: () => void }): ReactNode {
  return (
    <button onClick={onClick} className={cx('inline-flex items-center gap-[5px] whitespace-nowrap uppercase tracking-label hover:text-strong', active && 'text-strong')}>
      {/* Only the sorted column carries an arrow, before the label, so the label stays flush right */}
      {active && <Arrow dir={dir === 'desc' ? 'down' : 'up'} size={10} />}
      <span>{label}</span>
      <span className="sr-only">{active ? `, sorted ${dir === 'desc' ? 'descending' : 'ascending'}` : ', sortable'}</span>
    </button>
  );
}
