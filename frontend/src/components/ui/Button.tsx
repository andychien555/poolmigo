import type { ButtonHTMLAttributes, ReactNode } from 'react';
import { cx } from '@/lib/format';
import { Spinner } from './Spinner';

type Variant = 'primary' | 'accent' | 'secondary' | 'ghost' | 'danger';
type Size = 'sm' | 'md' | 'lg';

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  loading?: boolean;
  block?: boolean;
  children: ReactNode;
}

const variants: Record<Variant, string> = {
  primary: 'bg-fill-primary text-inverse-strong border border-stroke-primary hover:bg-fill-primary-hover hover:border-stroke-primary-hover disabled:bg-fill-disabled disabled:border-stroke-strong disabled:text-disabled',
  accent: 'bg-fill-accent text-on-accent border border-stroke-accent hover:bg-fill-accent-hover hover:border-stroke-accent-hover disabled:bg-fill-disabled disabled:border-stroke-strong disabled:text-disabled',
  secondary: 'bg-transparent text-strong border border-stroke-strong hover:border-stroke-strongest disabled:text-disabled disabled:hover:border-stroke-strong',
  ghost: 'bg-transparent text-weak border border-transparent hover:text-strong hover:bg-fill-hover disabled:text-disabled',
  danger: 'bg-transparent text-error border border-stroke-error/40 hover:bg-fill-error/10',
};

const sizes: Record<Size, string> = {
  sm: 'h-9 px-3 text-sm',
  md: 'h-11 px-[18px] text-base',
  lg: 'h-12 px-5 text-md',
};

export function Button({ variant = 'primary', size = 'md', loading, block, className, children, disabled, ...rest }: Props) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={cx(
        'inline-flex items-center justify-center gap-3 rounded font-medium transition-colors duration-300 ease-dusk select-none whitespace-nowrap disabled:cursor-not-allowed',
        variants[variant],
        sizes[size],
        block && 'w-full',
        className,
      )}
    >
      {loading && <Spinner className="h-4 w-[26px]" />}
      <span className={cx(loading && 'opacity-80')}>{children}</span>
    </button>
  );
}
