/**
 * One registry vault, `/vault/<chainId>-<key>` (or the classic `/vault/<key>` when only one chain
 * lists that key), as the original vault page laid it out — stats, the deposit / withdraw card in
 * the side column, the price range, the basket, the price chart — read live
 * (src/chain/useLiveVaults.ts + src/chain/useVault.ts): TVL and spot NAV at the reference pools'
 * live spot, receipt supply and cap, performance fee, the basket composition and the exact spot
 * prices used, and the price range: the live spot between the adapters' on-chain range
 * (src/chain/useVaultRanges.ts). The card's deposits and withdrawals are real transactions on this
 * vault's chain. Mocked, and badged: the price chart's line only (no history on chain) — never the
 * live price or the spot-NAV readout. The fee APR (stat row + "Your APR") and "Fees earned" come from the
 * NAV-history collector (src/chain/feeApy.ts) through the chart's own fetch; "—" until 7 days are covered.
 */
import { useEffect, useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useWallet } from '@/wallet/context';
import { DEPLOYMENTS, chainFor, chainLabel, findVault, isLocalChain } from '@/chain/chains';
import { formatAmount, formatAmountSignificant, shortHex } from '@/chain/amounts';
import { basketName, feeLabel, holdingUsd, resolveVaultRouteId, tokenUsdPrices, vaultRouteId } from '@/chain/liveVaults';
import { USD_ANCHOR_SYMBOL, spotUsdPerToken } from '@/chain/spot';
import { anchorOf, useLiveVaults, type LiveVaultRow } from '@/chain/useLiveVaults';
import { useOpenVault, useSwitchToChain } from '@/chain/useTargetChain';
import { useLiveVaultAt, useUserBasket } from '@/chain/useVault';
import { describeSwitchError } from '@/chain/switchChain';
import type { ChainSpots } from '@/chain/useSpotPrices';
import { useVaultRanges } from '@/chain/useVaultRanges';
import { FEE_APR_WINDOW_DAYS, feeApyPct, fmtFeeApr, latestFeesUsd } from '@/chain/feeApy';
import { useNavHistoryRows } from '@/chain/useNavHistory';
import { cx, fmtPct, fmtPrice, fmtUsd } from '@/lib/format';
import { TokenGroup } from '@/components/ui/TokenIcon';
import { Stat, StatRow } from '@/components/ui/Stat';
import { Button } from '@/components/ui/Button';
import { Tooltip } from '@/components/ui/Tooltip';
import { LiveBadge } from '@/components/ui/DataBadge';
import { NavChart } from '@/components/vault/NavChart';
import { PriceRange } from '@/components/vault/PriceRange';
import { rangePairsFor } from '@/components/vault/rangePairs';
import { DepositCard } from '@/components/deposit/DepositCard';
import { LocalDevPanel } from '@/components/live/LocalDevPanel';
import { Message } from '@/components/live/Message';
import { NetworkManual } from '@/components/live/NetworkManual';

export function VaultDetail() {
  const { id = '' } = useParams();
  const { address } = useWallet();
  const { rows, spotsFor } = useLiveVaults(address ?? undefined);
  const resolved = resolveVaultRouteId(id, DEPLOYMENTS);
  if (resolved.kind === 'ambiguous') {
    return (
      <div className="wrap pt-[26px] text-sm text-weaker">
        <p>
          <span className="text-strong">{id}</span> names a vault on more than one network. Which one?
        </p>
        <ul className="mt-3 grid gap-1.5">
          {resolved.matches.map((m) => (
            <li key={m.chainId}>
              <Link to={`/vault/${vaultRouteId(m.chainId, m.key)}`} className="text-strong hover:underline">
                {findVault(m.chainId, m.key)?.label ?? m.key} — {chainLabel(m.chainId)}
              </Link>
            </li>
          ))}
        </ul>
      </div>
    );
  }
  const ref = resolved.kind === 'found' ? resolved.ref : undefined;
  const row = ref && rows.find((r) => r.v.chainId === ref.chainId && r.v.entry.key === ref.key);
  if (!row) {
    return (
      <div className="wrap pt-[26px] text-sm text-weaker">
        Vault not found. <Link to="/" className="text-strong">Back to vaults</Link>
      </div>
    );
  }
  return <VaultView key={row.id} row={row} spots={spotsFor(row.v.chainId)} />;
}

function VaultView({ row, spots }: { row: LiveVaultRow; spots: ChainSpots }) {
  const { v, valuation, nav } = row;
  const { address, chainId } = useWallet();
  const openVault = useOpenVault();
  const { switchTo, switching, error: switchError } = useSwitchToChain();
  // The vault the card reads and writes: this page's vault, whatever the header or wallet points at.
  const vault = useLiveVaultAt(v.chainId, v.entry);
  const user = useUserBasket(address ?? undefined, vault);
  const usdPrices = useMemo(() => tokenUsdPrices(v.tokens, spots.spots), [v.tokens, spots.spots]);
  const { bands } = useVaultRanges(v.chainId, v.address, v.tokens);
  const pairs = useMemo(() => rangePairsFor(v.tokens, usdPrices, bands), [v.tokens, usdPrices, bands]);
  // Looking at a vault selects its chain (and remembers the vault) in the header — no wallet prompt.
  useEffect(() => openVault(v.chainId, v.entry.key), [openVault, v.chainId, v.entry.key]);
  // The fee APR and cumulative fees: the collector's rows, the same fetch the NAV chart reads.
  const { rows: history } = useNavHistoryRows();
  const earnings = useMemo(
    () => ({ apr: feeApyPct(history, v.entry.key, FEE_APR_WINDOW_DAYS, v.chainId), fees: latestFeesUsd(history, v.entry.key, v.chainId) }),
    [history, v.entry.key, v.chainId],
  );

  const symbols = v.tokens.map((t) => t.symbol);
  const name = basketName(v.ready ? symbols : [], v.entry.label);
  const cap = v.maxTotalSupply;
  const usd = (x: number | undefined, cents = true) => (x === undefined ? '—' : fmtUsd(x, { cents }));
  const wrongChain = Boolean(address) && chainId !== v.chainId;
  const switchTarget = chainFor(v.chainId);

  return (
    <div className="wrap pt-[26px] pb-[120px]">
      <div className="grid items-start gap-x-10 gap-y-10 lg:grid-cols-[minmax(0,1fr)_384px]">
        <header className="grid gap-6 lg:col-start-1">
          <Link to="/" className="group -my-1.5 inline-flex items-center gap-3 justify-self-start py-1.5 text-md text-weak transition-colors duration-300 ease-dusk hover:text-strong">
            {/* BoxIcons arrow-back (react-icons BiArrowBack), filled with the link's colour so it follows the hover. */}
            <svg width="20" height="20" viewBox="0 0 24 24" className="shrink-0 transition-transform duration-300 ease-dusk group-hover:-translate-x-1" fill="currentColor" aria-hidden>
              <path d="M21 11H6.414l5.293-5.293-1.414-1.414L2.586 12l7.707 7.707 1.414-1.414L6.414 13H21z" />
            </svg>
            All vaults
          </Link>
          <div className="flex flex-wrap items-start gap-[18px] [--name:clamp(38px,4.4vw,60px)]">
            {symbols.length > 0 && <span className="flex shrink-0 mt-[calc((var(--name)-36px)/2)]"><TokenGroup symbols={symbols} size={36} /></span>}
            <div>
              <h1 className="title !font-normal text-[length:var(--name)]">{name}</h1>
              <p className="num mt-2 flex flex-wrap items-center gap-2 text-sm text-weak">
                {v.entry.receipt.symbol} · {v.chainName} · <span title={v.address}>{shortHex(v.address)}</span>
                <LiveBadge />
              </p>
            </div>
          </div>
          {v.failed && <p className="text-sm text-warning">{v.chainName} RPC not reachable right now — figures will fill in when it answers.</p>}
          {v.paused && <p className="text-sm text-warning">Vault is paused — deposits, redemptions and keeper operations are frozen.</p>}
          {wrongChain && (
            <div className="grid gap-2">
              <Message tone="warn">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span>Your wallet is on {chainLabel(chainId)}. Figures below come from {v.chainName}; switch network to deposit or withdraw.</span>
                  <Button size="sm" variant="secondary" loading={switching} onClick={() => void switchTo(v.chainId).catch(() => {})}>
                    Switch to {v.chainName}
                  </Button>
                </div>
              </Message>
              {switchError && switchTarget && <Message tone="error">{describeSwitchError(switchError, switchTarget)}</Message>}
            </div>
          )}
          <StatRow cols={5}>
            <Stat label="TVL" value={usd(valuation.usd)} sub={valuation.unpriced.length > 0 ? `no price for ${valuation.unpriced.join(', ')}` : undefined} />
            {/* The fee APR alone, as the original design's stat row drew it */}
            <Stat label="APR" value={fmtFeeApr(earnings.apr)} />
            <Stat label="Spot NAV" value={nav === undefined ? '—' : fmtPrice(nav)} sub={`per ${v.entry.receipt.symbol}`} />
            <Stat label="Supply" value={v.supply === undefined ? '—' : formatAmountSignificant(v.supply, v.decimals)} sub={cap === undefined ? undefined : cap === 0n ? 'uncapped' : `cap ${formatAmountSignificant(cap, v.decimals)}`} />
            <Stat label="Performance fee" value={feeLabel(v.performanceFeeBps)} sub="on harvested fees only" />
          </StatRow>
        </header>

        <aside className="grid gap-3.5 lg:sticky lg:top-20 lg:col-start-2 lg:row-span-4 lg:row-start-1">
          {address && <YourPosition row={row} apr={earnings.apr} fees={earnings.fees} />}
          <DepositCard vault={vault} user={user} usdPrices={usdPrices} nav={nav} showVaultLink={false} />
          {wrongChain && <NetworkManual chainId={v.chainId} />}
          {/* Demo chain only, with no wallet on another network: fund the wallet from the local node. */}
          {isLocalChain(v.chainId) && !wrongChain && vault.tokens.length > 0 && <LocalDevPanel vault={vault} user={user} />}
        </aside>

        {pairs.length > 0 && <PriceRange pairs={pairs} className="min-w-0 lg:col-start-1" />}

        <section className="min-w-0 lg:col-start-1">
          <h2 className="title text-2xl leading-tight mb-3.5">Basket</h2>
          {/* Each token's share of the spot value, in the table's order; the Share column has the numbers */}
          {valuation.usd !== undefined && valuation.usd > 0 && (
            <div className="mb-4 flex h-1.5 w-full overflow-hidden rounded-full bg-fill-track" aria-hidden>
              {valuation.legs.map((l, i) => (
                <span key={i} className={cx('h-full', i % 2 === 0 ? 'bg-fill-primary' : 'bg-strong/40')} style={{ width: `${(l.share ?? 0) * 100}%` }} />
              ))}
            </div>
          )}
          <table className="w-full text-sm num">
            <thead>
              <tr className="text-xs text-weaker border-b border-stroke-strong">
                <th className="text-left font-medium pb-2">Token</th>
                <th className="text-right font-medium pb-2">In the vault</th>
                <th className="text-right font-medium pb-2">Spot price</th>
                <th className="text-right font-medium pb-2">Value</th>
                <th className="text-right font-medium pb-2">Share</th>
              </tr>
            </thead>
            <tbody>
              {v.tokens.map((t, i) => {
                const leg = valuation.legs[i];
                const anchor = anchorOf(v.tokens);
                const price = t.symbol === USD_ANCHOR_SYMBOL ? 1 : leg?.spot && anchor ? spotUsdPerToken(leg.spot, t.decimals, anchor.decimals) : undefined;
                return (
                  <tr key={t.address} className="border-b border-stroke-weak">
                    <td className="py-2.5 text-strong">{t.symbol}</td>
                    <td className="py-2.5 text-right text-strong">{formatAmount(t.total, t.decimals, 6)}</td>
                    <td className="py-2.5 text-right text-weak">{price === undefined ? '—' : fmtPrice(price)}</td>
                    <td className="py-2.5 text-right text-weak">{usd(leg?.usd)}</td>
                    <td className="py-2.5 text-right text-weak">{leg?.share === undefined ? '—' : fmtPct(leg.share)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <PricesUsed row={row} spots={spots} />
        </section>

        <NavChart seed={row.id} chainId={v.chainId} vaultKey={v.entry.key} symbol={v.entry.receipt.symbol} liveNav={nav} className="min-w-0 lg:col-start-1" />
      </div>
    </div>
  );
}

/**
 * The wallet's live holding: receipt balance, and its slice of the spot TVL — then the original design's
 * earnings rows: the vault's cumulative harvested fees, and the fee APR (7-day average, annualised).
 */
function YourPosition({ row: { v, valuation }, apr, fees }: { row: LiveVaultRow; apr: number | undefined; fees: number | undefined }) {
  if (!v.receiptBalance) return null;
  const value = holdingUsd(v.receiptBalance, v.supply, valuation.usd);
  return (
    <section className="grid gap-3 rounded-lg border border-stroke-strong bg-background-elevated px-[18px] pb-[18px] pt-4">
      <h2 className="eyebrow">Your position</h2>
      <div className="display num text-[34px] leading-none tracking-[-0.015em]">{value === undefined ? '—' : fmtUsd(value, { compact: false, cents: true })}</div>
      <p className="num text-sm text-weak">
        {formatAmountSignificant(v.receiptBalance, v.decimals)} {v.entry.receipt.symbol}
        {v.supply ? <> · {fmtPct(Number(v.receiptBalance) / Number(v.supply))} of supply</> : null}
      </p>
      <dl className="num text-sm">
        <Row
          label="Fees earned"
          value={fees === undefined ? '—' : fmtUsd(fees, { compact: false, cents: true })}
          tone={fees === undefined ? 'text-weaker' : 'text-success'}
          tip={`Trading fees the vault has harvested, all holders together. Fees compound into your ${v.entry.receipt.symbol} automatically. Nothing to claim.`}
        />
        <Row label="Your APR" value={fmtFeeApr(apr)} sub="7-day average, annualised" tip="From trading fees: the 7-day average, annualised." />
      </dl>
    </section>
  );
}

function Row({ label, value, sub, tone, tip }: { label: string; value: string; sub?: string; tone?: string; tip: string }) {
  return (
    <Tooltip content={tip} align="start" side="bottom" wide className="flex w-full">
      <div className="flex w-full cursor-help justify-between gap-2.5 border-t border-stroke-weak py-[7px]">
        <dt className="text-weaker">
          {label}
          {sub && <span className="block text-2xs">{sub}</span>}
        </dt>
        <dd className={cx(tone ?? 'text-strong')}>{value}</dd>
      </div>
    </Tooltip>
  );
}

/** Where each USD figure comes from: the reference pool and fee tier behind every spot. */
function PricesUsed({ row: { v }, spots }: { row: LiveVaultRow; spots: ChainSpots }) {
  const lines = v.tokens.flatMap((t) => {
    const s = spots.spots.get(t.address.toLowerCase());
    return s ? [{ symbol: t.symbol, pool: s.pool, fee: s.fee }] : [];
  });
  return (
    <p className={cx('mt-3 text-2xs text-weaker leading-relaxed')}>
      {USD_ANCHOR_SYMBOL} at its $1 peg
      {lines.map((l) => (
        <span key={l.pool}>
          {' · '}
          {l.symbol} at the live spot of pool <span title={l.pool}>{shortHex(l.pool)}</span>
          {l.fee !== undefined && <> ({(l.fee / 10_000).toFixed(2)}%)</>}
        </span>
      ))}
      . No oracle, no TWAP — display only.
    </p>
  );
}
