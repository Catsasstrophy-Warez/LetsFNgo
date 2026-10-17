import { colors } from '../data/colors';
import { production } from '../data/production';
import type { PaintColor, ProductionFact } from '../data/types';

/** Production records that are per-color counts, keyed by color id. */
const COLOR_COUNTS: Record<string, string> = {
  'performance-blue': 'c20-fpb', 'shadow-black': 'c20-black', 'rapid-red': 'c20-rapid', 'oxford-white': 'c20-oxford', 'race-red': 'c20-race', 'grabber-lime': 'lime-2020',
};

export interface PaintInfo { color: PaintColor; count: ProductionFact | null; rank: number | null; rankOf: number }

/**
 * Sourced 2020 count and rarity rank (1 = rarest) among the colors that have a count.
 * Colors without a sourced count get rank null — they are not assumed rarer or more common.
 */
export function paintInfo(id: string): PaintInfo | null {
  const color = colors.find((c) => c.id === id);
  if (!color) return null;
  const counted = Object.entries(COLOR_COUNTS)
    .map(([cid, pid]) => ({ cid, p: production.find((x) => x.id === pid)! }))
    .filter((x) => x.p && typeof x.p.value === 'number')
    .sort((a, b) => (a.p.value as number) - (b.p.value as number));
  const i = counted.findIndex((x) => x.cid === id);
  return { color, count: i >= 0 ? counted[i].p : null, rank: i >= 0 ? i + 1 : null, rankOf: counted.length };
}

/** Colors documented for a year (or all). */
export const paintsFor = (year: number | 'all') => colors.filter((c) => year === 'all' || c.years.includes(year as 2020));

/** Pick a readable stripe for a body color (illustrative only; no stripe colors are sourced here). */
export function stripeFor(hex: string): string {
  const m = /^#?([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i.exec(hex);
  if (!m) return '#f4f4f4';
  const [r, g, b] = m.slice(1).map((x) => parseInt(x, 16) / 255);
  const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  return lum > 0.6 ? '#16181c' : '#f4f4f4';
}
