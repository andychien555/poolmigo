export type Theme = 'light' | 'dark';

export interface Palette {
  ink: string; ink2: string; ink3: string; line: string; grid: string; panel: string; panel2: string;
  aqua: string; up: string; down: string; amber: string; apricot: string; glass: string;
}

// Dusk is dark only, so there is one palette. Keep it in step with src/index.css.
const DUSK: Palette = {
  ink: '#EFE3D1', ink2: '#C4B19D', ink3: '#9C8878', line: '#49403E', grid: '#2F2727', panel: '#2A1B20', panel2: '#36242A',
  aqua: '#EFE3D1', up: '#92D6A6', down: '#FF8A8F', amber: '#E0B07A', apricot: '#FFAE3D', glass: '#B36D5F',
};

/** Hex palette for chart libraries that can't read CSS variables. */
export function usePalette(): Palette {
  return DUSK;
}
