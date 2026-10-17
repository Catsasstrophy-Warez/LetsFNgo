/**
 * Buyer's guide: a pre-purchase checklist and price positioning built only from existing sourced records
 * (recalls, maintenance, packages, editions, colors, auctions, market stats). Nothing here is a new fact and
 * there is no valuation model: an asking price is only placed among sourced sale results.
 */
import { recalls } from '../data/recalls';
import { maintenance } from '../data/maintenance';
import { packages } from '../data/packages';
import { editions } from '../data/editions';
import { colors } from '../data/colors';
import { auctionResults, marketStats } from '../data/auctions';
import type { AuctionResult, Confidence, MarketStat, ModelYear, RecallIssue } from '../data/types';
import { coversYear, recallChecklist } from './report';
import { priced, median } from './market';

export type BuySection = 'recalls' | 'issues' | 'service' | 'equipment' | 'paint';
export const BUY_SECTIONS: BuySection[] = ['recalls', 'issues', 'service', 'equipment', 'paint'];
export interface BuyItem { id: string; section: BuySection; title: string; detail: string; source: string; confidence: Confidence; applies?: RecallIssue['appliesToGT500'];
  /** A labelled value the page translates the label of (data values stay English). */
  extra?: { key: 'build' | 'production' | 'code'; value: string } }

/** Maintenance records a buyer should ask about (service proof, warranty transfer and track-use terms, originality). */
export const BUY_MAINTENANCE_IDS = ['intervals', 'track-intervals', 'dct-fluid', 'w-b2b', 'w-pt', 'w-dct', 'w-cf', 'matching'];
const ISSUE_KINDS: RecallIssue['kind'][] = ['tsb', 'owner-report', 'vendor-claim', 'complaint'];

/** Recalls/campaigns that may apply to a model year (all 2020–22 when year is null). Excludes "does not apply". */
export const recallsFor = (year: ModelYear | null): RecallIssue[] => recallChecklist(year ? String(year) : '');

export function buildChecklist(year: ModelYear | null): BuyItem[] {
  const y = year ? String(year) : '';
  const out: BuyItem[] = [];
  for (const r of recallsFor(year)) out.push({ id: `recall:${r.id}`, section: 'recalls', title: `${r.campaign ?? r.id} — ${r.title}`, detail: r.summary, source: r.source, confidence: r.confidence, applies: r.appliesToGT500, ...(r.buildWindow ? { extra: { key: 'build' as const, value: r.buildWindow } } : {}) });
  for (const r of recalls.filter((x) => ISSUE_KINDS.includes(x.kind) && x.appliesToGT500 !== 'no' && coversYear(x.years, y))) out.push({ id: `issue:${r.id}`, section: 'issues', title: r.campaign ? `${r.campaign} — ${r.title}` : r.title, detail: r.summary, source: r.source, confidence: r.confidence, applies: r.appliesToGT500 });
  for (const id of BUY_MAINTENANCE_IDS) {
    const m = maintenance.find((x) => x.id === id);
    if (m) out.push({ id: `svc:${m.id}`, section: 'service', title: m.item, detail: [m.value === null ? '' : `${m.value}${m.unit ? ` ${m.unit}` : ''}`, m.warning ?? ''].filter(Boolean).join(' — '), source: m.source, confidence: m.confidence });
  }
  for (const p of packages.filter((x) => !year || x.years.includes(year))) out.push({ id: `pkg:${p.id}`, section: 'equipment', title: p.name, detail: p.contents.join('; '), source: p.source, confidence: p.confidence });
  for (const e of editions.filter((x) => !year || x.modelYears.includes(year))) out.push({ id: `ed:${e.id}`, section: 'equipment', title: e.name, detail: e.content ?? '', source: e.source, confidence: e.confidence, ...(e.production ? { extra: { key: 'production' as const, value: e.production } } : {}) });
  for (const c of colors.filter((x) => x.code && (!year || x.years.includes(year)))) out.push({ id: `paint:${c.id}`, section: 'paint', title: c.name, detail: '', extra: { key: 'code', value: c.code as string }, source: c.source, confidence: c.confidence });
  return out;
}

export interface PricePosition {
  /** Sourced completed sales with a USD price for the year (outliers excluded), cheapest first. */
  points: (AuctionResult & { price: number })[];
  below: number; above: number; same: number;
  median: number | null; min: number | null; max: number | null;
  /** The sales closest in mileage (up to 5), when a mileage was given. */
  nearMiles: (AuctionResult & { price: number })[];
  stats: MarketStat[];
}

/** Place an asking price among sourced sales for a model year. Counts only; no estimate is computed. */
export function positionPrice(asking: number, year: ModelYear, mileage: number | null, results: AuctionResult[] = auctionResults, stats: MarketStat[] = marketStats): PricePosition {
  const points = priced(results.filter((r) => r.year === year && !r.outlier)).sort((a, b) => a.price - b.price);
  const prices = points.map((p) => p.price);
  const nearMiles = mileage === null ? [] : points.filter((p) => p.mileage !== null).sort((a, b) => Math.abs((a.mileage as number) - mileage) - Math.abs((b.mileage as number) - mileage)).slice(0, 5);
  return {
    points, below: prices.filter((p) => p < asking).length, above: prices.filter((p) => p > asking).length, same: prices.filter((p) => p === asking).length,
    median: median(prices), min: prices.length ? prices[0] : null, max: prices.length ? prices[prices.length - 1] : null,
    nearMiles, stats: stats.filter((s) => s.year === year),
  };
}
