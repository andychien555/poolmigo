import type { ReactNode } from 'react';
import { cx } from '@/lib/format';

interface Props {
  label: ReactNode;
  value: ReactNode;
  sub?: ReactNode;
  tone?: 'default' | 'tide' | 'up' | 'down' | 'amber' | 'aqua';
  size?: 'md' | 'lg';
  className?: string;
  onClick?: () => void;
}

const tones = {
  default: 'text-ink',
  tide: 'text-tide',
  up: 'text-up',
  down: 'text-down',
  amber: 'text-amber',
  aqua: 'text-aqua',
};

export function Stat({ label, value, sub, tone = 'default', size = 'md', className, onClick }: Props) {
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag
      onClick={onClick}
      className={cx(
        'flex flex-col gap-1 text-left min-w-0',
        onClick && 'cursor-pointer group',
        className,
      )}
    >
      <div className="eyebrow">{label}</div>
      <div className={cx('display num truncate', size === 'lg' ? 'text-3xl' : 'text-[22px] leading-7', tones[tone], onClick && 'group-hover:underline decoration-1 underline-offset-4')}>{value}</div>
      {sub && <div className="text-xs text-ink-3 num">{sub}</div>}
    </Tag>
  );
}

/**
 * A row of readings on an engraved scale: each one hangs from a tick on the rule.
 * No panel and no dividers; the rule is the structure.
 * Below md the readings wrap into two columns, so each one carries its own short rule instead.
 */
export function StatRow({ children, className, cols = 4, packed }: { children: ReactNode; className?: string; cols?: 2 | 3 | 4; /** readings keep their own width and sit together at the start of the rule */ packed?: boolean }) {
  return (
    <div className={className}>
      <div className="ruler hidden md:block" aria-hidden />
      <div
        className={cx(
          'grid grid-cols-2 gap-x-3.5 gap-y-[18px] md:gap-x-7 md:gap-y-5',
          '[&>*]:relative [&>*]:border-t [&>*]:border-line-2 [&>*]:pt-2.5 md:[&>*]:border-t-0 md:[&>*]:pt-3',
          '[&>*]:before:absolute [&>*]:before:left-0 [&>*]:before:-top-px [&>*]:before:h-[7px] [&>*]:before:w-px [&>*]:before:bg-ink-2 md:[&>*]:before:-top-[9px] md:[&>*]:before:h-[13px]',
          packed
            ? 'md:flex md:flex-wrap md:gap-x-14 md:[&>*]:pr-2'
            : cols === 2 ? 'md:grid-cols-2' : cols === 3 ? 'md:grid-cols-3' : 'md:grid-cols-4',
        )}
      >
        {children}
      </div>
    </div>
  );
}
