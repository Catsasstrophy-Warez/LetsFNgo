/** 2020 vs 2021 vs 2022 differences and GT500-vs-rival head-to-head, generated only from sourced data. */
import { colors } from '../data/colors';
import { packages } from '../data/packages';
import { prices } from '../data/pricing';
import { competitors } from '../data/competitors';
import type { Competitor, CompetitorSheet, Confidence, ModelYear, OptionPackage, PaintColor, PriceRecord } from '../data/types';

export const YEARS: ModelYear[] = [2020, 2021, 2022];

export interface PresenceRow<T> { item: T; years: Record<ModelYear, boolean>; /** Listed in some years but not all. */ differs: boolean }

function presence<T extends { years: ModelYear[] }>(items: T[]): PresenceRow<T>[] {
  return items.map((item) => {
    const years = { 2020: item.years.includes(2020), 2021: item.years.includes(2021), 2022: item.years.includes(2022) } as Record<ModelYear, boolean>;
    return { item, years, differs: new Set(Object.values(years)).size > 1 };
  });
}

export const colorRows = (): PresenceRow<PaintColor>[] => presence(colors);
/** Packages with no sourced year list are left out (nothing to compare). */
export const packageRows = (): PresenceRow<OptionPackage>[] => presence(packages.filter((p) => p.years.length));

/** Price records grouped by kind then year; a cell holds every sourced record (conflicts stay visible). Null values are kept so "unknown" shows. */
export function priceGrid(): { kind: PriceRecord['kind']; cells: Record<ModelYear, PriceRecord[]> }[] {
  const kinds: PriceRecord['kind'][] = ['msrp', 'destination', 'gas-guzzler', 'delivered', 'as-tested'];
  return kinds.map((kind) => ({
    kind,
    cells: Object.fromEntries(YEARS.map((y) => [y, prices.filter((p) => p.kind === kind && p.year === y)])) as Record<ModelYear, PriceRecord[]>,
  })).filter((r) => YEARS.some((y) => r.cells[y].length));
}

export function yearCounts() {
  const c = colorRows(); const p = packageRows();
  return YEARS.map((y) => ({ year: y, colors: c.filter((r) => r.years[y]).length, packages: p.filter((r) => r.years[y]).length }));
}

export interface H2HRow { label: string; gt500: string | null; rival: string | null; /** Which side is better, only for comparable numeric fields. */ better: 'gt500' | 'rival' | 'tie' | null }
export interface H2H { gt500: Competitor; rival: Competitor; gtSheet: CompetitorSheet | null; rivalSheet: CompetitorSheet | null; rows: H2HRow[] }

export const rivals = (includeHidden = false) => competitors.filter((c) => c.id !== 'gt500' && (includeHidden || !c.sheet?.hidden));

const num = (x: number | null, unit: string) => (x === null ? null : `${x.toLocaleString('en-US')}${unit}`);
function cmp(a: number | null, b: number | null, lowerBetter: boolean): H2HRow['better'] {
  if (a === null || b === null) return null;
  if (a === b) return 'tie';
  return (a < b) === lowerBetter ? 'gt500' : 'rival';
}

/** Side-by-side rows; values are only those a source gives (null shows as "not sourced"). Hidden (unverified database) sheets are excluded unless asked. */
export function headToHead(rivalId: string, includeHidden = false): H2H | null {
  const gt500 = competitors.find((c) => c.id === 'gt500');
  const rival = competitors.find((c) => c.id === rivalId);
  if (!gt500 || !rival || rival.id === 'gt500') return null;
  const gs = gt500.sheet ?? null;
  const rs = rival.sheet && (includeHidden || !rival.sheet.hidden) ? rival.sheet : null;
  const rows: H2HRow[] = [
    { label: 'Horsepower', gt500: num(gs?.hp ?? null, ' hp'), rival: num(rs?.hp ?? null, ' hp'), better: cmp(gs?.hp ?? null, rs?.hp ?? null, false) },
    { label: 'Torque', gt500: num(gs?.torque ?? null, ' lb-ft'), rival: num(rs?.torque ?? null, ' lb-ft'), better: cmp(gs?.torque ?? null, rs?.torque ?? null, false) },
    { label: 'Weight', gt500: num(gs?.weightLb ?? null, ' lb'), rival: num(rs?.weightLb ?? null, ' lb'), better: cmp(gs?.weightLb ?? null, rs?.weightLb ?? null, true) },
    { label: '0–60 mph', gt500: num(gs?.zeroTo60 ?? null, ' s'), rival: num(rs?.zeroTo60 ?? null, ' s'), better: cmp(gs?.zeroTo60 ?? null, rs?.zeroTo60 ?? null, true) },
    { label: '¼ mile (spec sheet)', gt500: gs?.quarterMile ?? null, rival: rs?.quarterMile ?? null, better: null },
    { label: '¼ mile (comparison test)', gt500: gt500.quarterMile, rival: rival.quarterMile, better: null },
    { label: 'Lap', gt500: gt500.lap, rival: rival.lap, better: null },
    { label: 'Price', gt500: gt500.price, rival: rival.price, better: null },
  ];
  return { gt500, rival, gtSheet: gs, rivalSheet: rs, rows };
}

export const confRank: Record<Confidence, number> = { confirmed: 0, reported: 1, unverified: 2 };
