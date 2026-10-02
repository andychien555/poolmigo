import { cx } from '@/lib/format';

interface Props<T extends string> {
  value: T;
  onChange: (v: T) => void;
  options: Array<{ value: T; label: string; disabled?: boolean }>;
  size?: 'sm' | 'md';
  className?: string;
}

/** Segmented control — used for Deposit/Withdraw, 30D/7D, asset chips. */
export function Segmented<T extends string>({ value, onChange, options, size = 'md', className }: Props<T>) {
  return (
    <div className={cx('inline-flex rounded-lg border border-stroke-weak bg-background-elevated p-[3px]', className)} role="tablist">
      {options.map((o) => (
        <button
          key={o.value}
          role="tab"
          aria-selected={value === o.value}
          disabled={o.disabled}
          onClick={() => onChange(o.value)}
          className={cx(
            'rounded-sm transition-colors whitespace-nowrap disabled:opacity-40',
            size === 'sm' ? 'h-7 px-3 text-xs' : 'h-8 px-3 text-sm',
            value === o.value ? 'bg-fill-primary text-inverse-strong' : 'text-weak hover:text-strong',
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function UnderlineTabs<T extends string>({ value, onChange, options, className }: Props<T>) {
  return (
    <div className={cx('flex border-b border-stroke-weak', className)} role="tablist">
      {options.map((o) => (
        <button
          key={o.value}
          role="tab"
          aria-selected={value === o.value}
          onClick={() => onChange(o.value)}
          className={cx(
            'h-11 px-4 text-sm font-medium -mb-px border-b-2 transition-colors',
            value === o.value ? 'border-stroke-selected text-strong' : 'border-transparent text-weaker hover:text-weak',
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
