import type { Config } from 'tailwindcss';

// Design tokens — Dusk direction. Values live in CSS variables (src/index.css) so every
// utility name stays the one the components already use.
//
// Dusk is dark only. One rule shapes it: only the price is round. The sun, the price needle
// and price points are circles; everything structural (ranges, controls, cards, token tiles)
// is square-cut. That is why the radius scale below is small all the way up to `full`.
// Draw a real circle with `rounded-circle`.
const v = (name: string) => `rgb(var(--c-${name}) / <alpha-value>)`;

export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    colors: {
      transparent: 'transparent',
      current: 'currentColor',
      white: '#FFFFFF',
      black: '#000000',
      deep: v('deep'),
      dusk: v('dusk'),
      panel: v('panel'),
      'panel-2': v('panel-2'),
      line: v('line'),
      'line-2': v('line-2'),
      ink: v('ink'),
      'ink-2': v('ink-2'),
      'ink-3': v('ink-3'),
      aqua: v('aqua'),
      'aqua-dim': v('aqua-dim'),
      up: v('up'),
      down: v('down'),
      amber: v('amber'),
      apricot: v('apricot'),
      glass: v('glass'),
      tide: v('tide'),
      sun: v('sun'),
      'sun-core': v('sun-core'),
      'on-primary': v('on-primary'),
      'on-accent': v('on-accent'),
    },
    fontFamily: {
      // `display` is the emphasis face for numbers and UI titles; the serif is for page-level titles.
      // "Switzer Figures" holds only figures and their signs (src/index.css), so it leads both stacks:
      // every figure is set in Switzer, every letter in Geist.
      display: ['"Switzer Figures"', 'Geist', '"Helvetica Neue"', 'Helvetica', 'Arial', 'sans-serif'],
      sans: ['"Switzer Figures"', 'Geist', '"Helvetica Neue"', 'Helvetica', 'Arial', 'sans-serif'],
      serif: ['Zodiak', '"Iowan Old Style"', '"Palatino Linotype"', 'Georgia', 'serif'],
      mono: ['"Geist Mono"', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
    },
    // Geist carries emphasis at 500; 600 is the ceiling.
    fontWeight: { thin: '100', light: '300', normal: '400', medium: '500', semibold: '500', bold: '600' },
    borderRadius: { none: '0', sm: '2px', DEFAULT: '3px', md: '3px', lg: '4px', full: '2px', circle: '50%' },
    extend: {
      fontSize: {
        '2xs': ['11px', '14px'],
        xs: ['12px', '16px'],
        sm: ['13px', '18px'],
        base: ['14px', '20px'],
        md: ['15px', '22px'],
        lg: ['17px', '24px'],
        xl: ['20px', '26px'],
        '2xl': ['24px', '30px'],
        '3xl': ['30px', '36px'],
        '4xl': ['38px', '44px'],
      },
      letterSpacing: { label: '0.14em' },
      boxShadow: { pop: '0 20px 50px rgb(var(--c-shadow) / 0.5), 0 0 0 1px rgb(var(--c-line-2))' },
      transitionTimingFunction: { dusk: 'cubic-bezier(0.65, 0, 0.35, 1)' },
      keyframes: {
        'fade-in': { from: { opacity: '0', transform: 'translateY(4px)' }, to: { opacity: '1', transform: 'translateY(0)' } },
        'slide-in': { from: { opacity: '0', transform: 'translateX(40px)' }, to: { opacity: '1', transform: 'translateX(0)' } },
        rise: { from: { transform: 'translateY(8px)' }, to: { transform: 'translateY(-2px)' } },
        spin: { to: { transform: 'rotate(360deg)' } },
      },
      animation: {
        'fade-in': 'fade-in 160ms ease-out',
        'slide-in': 'slide-in 450ms cubic-bezier(0.65, 0, 0.35, 1)',
        rise: 'rise 2s cubic-bezier(0.65, 0, 0.35, 1) infinite alternate',
        spin: 'spin 800ms linear infinite',
      },
    },
  },
  plugins: [],
} satisfies Config;
