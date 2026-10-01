import { useId } from 'react';
import type { Vault } from '@/lib/types';
import * as m from '@/demo/math';
import type { MarketStatus } from '@/lib/market';
import { fmtQuote, fmtRelativeDays } from '@/lib/format';
import { useElementWidth } from '@/lib/useElementWidth';

interface Props {
  vault: Vault;
  market: MarketStatus;
  className?: string;
}

const HEIGHT = 300; // drawing height
const HORIZON = 238; // y of the ground line
const STONE_W = 18;
const STONE_H = 158;

/** Round scale marks covering [min, max], about `count` of them. */
function niceTicks(min: number, max: number, count: number): number[] {
  const raw = (max - min) / count;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((k) => k * mag).find((s) => s >= raw) ?? raw;
  const out: number[] = [];
  for (let v = Math.ceil(min / step) * step; v <= max + 1e-12; v += step) out.push(v);
  return out;
}

/**
 * Price range as the instrument itself: a sky, two stones standing on the bounds, the sun at the
 * current price, and a graduated horizon as the price axis. The stones' inner faces sit exactly
 * on Lower and Upper, so the gap between them is the range.
 */
export function PriceRange({ vault: v, market, className }: Props) {
  const id = useId();
  const [host, width] = useElementWidth<HTMLDivElement>();
  const W = Math.max(320, width);
  const g = m.rangeGeometry(v, market);
  const inRange = v.currentPrice >= g.lower && v.currentPrice <= g.upper;

  // price → x: the scale runs 24% of the range width past each bound
  const span = g.upper - g.lower, pad = 20;
  const d0 = g.lower - span * 0.24, d1 = g.upper + span * 0.24;
  const X = (p: number) => pad + ((p - d0) / (d1 - d0)) * (W - pad * 2);
  // a price beyond the scale stops at its end, so the sun never leaves the frame
  const sunX = Math.min(W - pad - 24, Math.max(pad + 24, X(v.currentPrice)));

  const ticks = niceTicks(d0, d1, Math.max(4, Math.floor(W / 110)));
  const step = ticks.length > 1 ? ticks[1] - ticks[0] : span;
  // scale figures carry just enough decimals for the step between them
  const tickDigits = Math.max(0, -Math.floor(Math.log10(step) + 1e-9));
  const minor: Array<{ x: number; major: boolean }> = [];
  for (let t = ticks[0] - step; t <= d1; t += step / 5) {
    if (t < d0) continue;
    minor.push({ x: X(t), major: Math.abs(t / step - Math.round(t / step)) < 1e-6 });
  }
  let dunes = `M0 ${HORIZON}`;
  for (let x = 0; x <= W; x += 20) dunes += ` L${x} ${(HORIZON - 5 - 4 * Math.sin(x * 0.013) - 3 * Math.sin(x * 0.031 + 1.2)).toFixed(1)}`;
  dunes += ` L${W} ${HORIZON} Z`;

  const sky = `${id}-sky`, glow = `${id}-glow`, sun = `${id}-sun`, stone = `${id}-stone`, above = `${id}-above`;
  const label = { fontSize: 10, letterSpacing: '0.12em' } as const;
  const figure = { fontWeight: 500, paintOrder: 'stroke', stroke: 'rgb(21 13 16 / 0.7)', strokeWidth: 3, strokeLinejoin: 'round' } as const;

  return (
    <section className={className} aria-label="Price range">
      <div className="overflow-hidden rounded-lg border border-line-2 bg-deep">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-line px-4 py-[11px] text-xs text-ink-3">
          <h3><b className="text-sm font-medium text-ink">Price range</b> · {v.token1} per {v.token0}</h3>
          <span className="num">
            {g.defensive && <span className="text-amber">Widened while the US market is closed · </span>}
            {!g.defensive && !inRange && <span className="text-down">Out of range · </span>}
            Last rebalance {fmtRelativeDays(v.lastRebalanceDaysAgo)}
          </span>
        </header>
        <div ref={host}>
          <svg
            viewBox={`0 0 ${W} ${HEIGHT}`}
            className="block h-auto w-full"
            role="img"
            aria-label={`Price ${fmtQuote(v.currentPrice)} ${inRange ? 'between' : 'outside'} the lower bound ${fmtQuote(g.lower)} and the upper bound ${fmtQuote(g.upper)}`}
          >
            <defs>
              <linearGradient id={sky} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor="#140b0f" />
                <stop offset=".5" stopColor="#35202a" />
                <stop offset=".86" stopColor="#7d4745" />
                <stop offset="1" stopColor="#a45d4b" />
              </linearGradient>
              <radialGradient id={glow} cx={sunX} cy={HORIZON} r={Math.min(260, W * 0.34)} gradientUnits="userSpaceOnUse">
                <stop offset="0" stopColor="#ffb066" stopOpacity=".55" />
                <stop offset="1" stopColor="#ffb066" stopOpacity="0" />
              </radialGradient>
              <radialGradient id={sun}>
                <stop offset=".15" stopColor="#fff0cc" />
                <stop offset="1" stopColor="#ff9a4a" />
              </radialGradient>
              <linearGradient id={stone} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor="#eadbc9" />
                <stop offset="1" stopColor="#b3917e" />
              </linearGradient>
              <clipPath id={above}><rect x="0" y="0" width={W} height={HORIZON} /></clipPath>
            </defs>

            <rect x="0" y="0" width={W} height={HORIZON} fill={`url(#${sky})`} />
            <rect x="0" y="0" width={W} height={HORIZON} fill={`url(#${glow})`} />
            <path d={dunes} fill="#5b3438" opacity=".8" />
            {/* the price: the sun, partly set */}
            <g clipPath={`url(#${above})`}><circle cx={sunX} cy={HORIZON - 2} r="24" fill={`url(#${sun})`} /></g>
            {/* the bounds: inner faces sit exactly on Lower and Upper, lit from the sun's side */}
            <rect x={X(g.lower) - STONE_W} y={HORIZON - STONE_H} width={STONE_W} height={STONE_H} fill={`url(#${stone})`} />
            <rect x={X(g.lower) - 2} y={HORIZON - STONE_H} width="2" height={STONE_H} fill="#ffd9a0" opacity=".55" />
            <rect x={X(g.upper)} y={HORIZON - STONE_H} width={STONE_W} height={STONE_H} fill={`url(#${stone})`} />
            <rect x={X(g.upper)} y={HORIZON - STONE_H} width="2" height={STONE_H} fill="#ffd9a0" opacity=".55" />
            {/* the range, lit on the horizon */}
            <rect x={X(g.lower)} y={HORIZON - 3} width={X(g.upper) - X(g.lower)} height="3" className="fill-sun" opacity={inRange ? 0.55 : 0.2} />

            <text x={X(g.lower) - STONE_W / 2} y={HORIZON - STONE_H - 31} textAnchor="middle" className="fill-ink-2" {...label}>LOWER</text>
            <text x={X(g.lower) - STONE_W / 2} y={HORIZON - STONE_H - 10} textAnchor="middle" fontSize="15" className="fill-ink num" {...figure}>{fmtQuote(g.lower)}</text>
            <text x={X(g.upper) + STONE_W / 2} y={HORIZON - STONE_H - 31} textAnchor="middle" className="fill-ink-2" {...label}>UPPER</text>
            <text x={X(g.upper) + STONE_W / 2} y={HORIZON - STONE_H - 10} textAnchor="middle" fontSize="15" className="fill-ink num" {...figure}>{fmtQuote(g.upper)}</text>
            <text x={sunX} y={HORIZON - 72} textAnchor="middle" className="fill-ink-2" {...label}>PRICE</text>
            <text x={sunX} y={HORIZON - 44} textAnchor="middle" fontSize="22" className="fill-sun-core num" {...figure}>{fmtQuote(v.currentPrice)}</text>

            {/* the graduated horizon: the price axis */}
            <rect x="0" y={HORIZON} width={W} height={HEIGHT - HORIZON} fill="#1b1115" />
            <rect x="0" y={HORIZON} width={W} height="1" className="fill-line-2" />
            {minor.map((t, i) => <rect key={i} x={t.x} y={HORIZON + 1} width="1" height={t.major ? 10 : 5} className="fill-ink-3" opacity={t.major ? 0.9 : 0.5} />)}
            {ticks.map((t) => <text key={t} x={X(t)} y={HORIZON + 28} textAnchor="middle" fontSize="11" className="fill-ink-3 num">{t.toFixed(tickDigits)}</text>)}
          </svg>
        </div>
      </div>
    </section>
  );
}
