import type { AuctionResult, ModelYear } from '../data/types';

/** Filters for the Market page. `null` means "any". */
export interface MarketFilter { year: ModelYear | null; cftp: boolean | null; heritage: boolean | null; includeOutliers: boolean; includeOffers: boolean }
export const DEFAULT_FILTER: MarketFilter = { year: null, cftp: null, heritage: null, includeOutliers: false, includeOffers: false };

/**
 * Apply filters. A CFTP/Heritage filter only keeps results whose source states that attribute
 * (null = not stated is never treated as a match for "yes" or "no").
 */
export function filterAuctions(list: AuctionResult[], f: MarketFilter): AuctionResult[] {
  return list.filter((r) =>
    (f.year === null || r.year === f.year)
    && (f.cftp === null || r.cftp === f.cftp)
    && (f.heritage === null || r.heritage === f.heritage)
    && (f.includeOutliers || !r.outlier)
    && (f.includeOffers || r.outcome === 'sold'));
}

/** Results that can be charted: completed sales with a USD price. */
export const priced = (list: AuctionResult[]) => list.filter((r): r is AuctionResult & { price: number } => r.price !== null && r.outcome === 'sold');

/** Median of numbers (null for none). */
export function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

/** Fractional year for a YYYY-MM-DD or YYYY-MM date (mid-month when the day is unknown); null if unparseable. */
export function dateValue(d: string | null): number | null {
  const m = d ? /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(d) : null;
  if (!m) return null;
  const y = Number(m[1]), mo = Number(m[2]), day = m[3] ? Number(m[3]) : 15;
  if (mo < 1 || mo > 12 || day < 1 || day > 31) return null;
  const start = Date.UTC(y, 0, 1), end = Date.UTC(y + 1, 0, 1);
  return y + (Date.UTC(y, mo - 1, day) - start) / (end - start);
}

export interface ScatterPt { id: string; x: number; y: number; label: string }

/** Price-vs-date points (dated, priced sales only). */
export const byDate = (list: AuctionResult[]): ScatterPt[] => priced(list).flatMap((r) => {
  const x = dateValue(r.date);
  return x === null ? [] : [{ id: r.id, x, y: r.price, label: `${r.date} · ${r.venue ?? 'venue not stated'}` }];
});

/** Price-vs-mileage points (priced sales with known mileage). */
export const byMileage = (list: AuctionResult[]): ScatterPt[] => priced(list).flatMap((r) =>
  r.mileage === null ? [] : [{ id: r.id, x: r.mileage, y: r.price, label: `${r.mileage.toLocaleString('en-US')} mi · ${r.date ?? 'date unknown'}` }]);

export { usdWhole as usd0 } from './format';
