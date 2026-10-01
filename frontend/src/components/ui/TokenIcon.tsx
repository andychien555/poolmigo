import { TOKEN_COLORS } from '@/demo/data/vaults';
import type { ChainId } from '@/demo/data/chains';
import { ChainLogo } from './ChainLogo';
import { cx } from '@/lib/format';

/** A token as a square tile: its initial, with the token's own colour as a rule along the bottom edge. */
export function TokenIcon({ symbol, size = 22, className }: { symbol: string; size?: number; className?: string }) {
  const color = TOKEN_COLORS[symbol] ?? '#9C8878';
  const letter = symbol.replace(/x$/, '').slice(0, 1);
  return (
    <span
      className={cx('inline-flex items-center justify-center rounded bg-panel-2 border border-line-2 font-display font-bold text-ink shrink-0', className)}
      style={{ width: size, height: size, fontSize: Math.max(9, Math.round(size * 0.4)), boxShadow: `inset 0 -2px 0 ${color}` }}
      title={symbol}
    >
      {letter}
    </span>
  );
}

export function TokenPair({ a, b, size = 22, chain }: { a: string; b: string; size?: number; chain?: ChainId }) {
  return (
    <span className="relative inline-flex items-center shrink-0" style={{ width: size * 2 - 6, height: size }}>
      <TokenIcon symbol={a} size={size} className="relative z-10" />
      <TokenIcon symbol={b} size={size} className="-ml-1.5" />
      {chain && (
        <ChainLogo
          chain={chain}
          size={Math.round(size * 0.52)}
          className="absolute -bottom-[5px] -right-1.5 z-20 ring-[1.5px] ring-deep"
        />
      )}
    </span>
  );
}
