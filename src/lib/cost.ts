/**
 * Cost of ownership for one Garage car. Built from three clearly separated kinds of numbers:
 *  - sourced: the scheduled-service intervals (2021 owner-manual supplement, as in DEFAULT_REMINDERS), the EPA
 *    combined mpg and market medians / auction results — each with source and confidence;
 *  - user: anything the owner typed (prices, insurance, tires, fuel price, annual miles) or logged (fuel, service,
 *    mods, track sessions).
 * No part price for a scheduled service is sourced in this app, so every service is "price not sourced" unless the
 * owner types their own cost. Unpriced lines are listed but left out of the total, which then reads "at least".
 * The value comparison lists sourced data points next to the purchase price; it is not a forecast and no
 * depreciation curve is applied.
 */
import { auctionResults } from '../data/auctions';
import { SUPP21 } from '../data/maintenance';
import { specs } from '../data/specs';
import type { AuctionResult, Confidence, MarketStat, ModelYear, SourcedValue } from '../data/types';
import { marketStats } from '../data/auctions';
import { DEFAULT_REMINDERS, type LogEntry, type Reminder } from './garage';
import type { FillUp } from './fuel';
import { fuelSummary, ownershipCost } from './fuel';
import { median, priced } from './market';
import type { CostInputs } from './costStore';

export type Origin = 'sourced' | 'user' | 'mixed';

/** A scheduled service from the sourced schedule. */
export interface ScheduledService { id: string; item: string; everyMiles: number | null; everyMonths: number | null; source: string; confidence: Confidence }
/** The sourced normal schedule (same intervals as the default Garage reminders). */
export const SCHEDULE: ScheduledService[] = DEFAULT_REMINDERS.map((r: Reminder) => ({ id: r.id, item: r.item, everyMiles: r.everyMiles, everyMonths: r.everyMonths, source: SUPP21, confidence: 'reported' as Confidence }));

/**
 * Sourced part / service prices by service id. Empty: no cited source in src/data gives a price for any scheduled
 * service. Add an entry only with a source; the page then uses it and labels it as sourced.
 */
export const SOURCED_SERVICE_PRICES: Record<string, SourcedValue<number>> = {};

export interface CostLine {
  id: string;
  kind: 'service' | 'fuel' | 'insurance' | 'tires';
  /** Service name (English source text) for service lines. */
  item?: string;
  /** Times due over the ownership period (service lines). */
  times?: number;
  /** Price of one occurrence (service) — null when neither sourced nor typed. */
  unitPrice?: number | null;
  /** Cost per year; null = unpriced (excluded from the total). */
  perYear: number | null;
  /** Where the price came from; null when unpriced. */
  priceOrigin: Origin | null;
  /** Sourced basis (interval, mpg or price) when there is one. */
  source?: string;
  confidence?: Confidence;
  /** mpg used for fuel and where it came from. */
  mpg?: { value: number; origin: 'user' | 'sourced'; source?: string; confidence?: Confidence } | null;
}

export interface CostEstimate {
  ready: boolean;
  lines: CostLine[];
  /** Services not due within the period (listed for completeness, not unpriced). */
  notDue: ScheduledService[];
  perYear: number; total: number; perMile: number | null;
  unpriced: number; atLeast: boolean;
}

/** Times a service falls due in `years` at `annualMiles`: whichever interval (miles or months) comes first. */
export function timesDue(s: Pick<ScheduledService, 'everyMiles' | 'everyMonths'>, annualMiles: number, years: number): number {
  const byMiles = s.everyMiles ? Math.floor((annualMiles * years) / s.everyMiles + 1e-9) : 0;
  const byMonths = s.everyMonths ? Math.floor((years * 12) / s.everyMonths + 1e-9) : 0;
  return Math.max(byMiles, byMonths);
}

const mpgSpec = specs.find((s) => s.id === 'mpg');
/** EPA combined mpg from the sourced spec ("12 city / 18 hwy / 14 combined"), or null. */
export function epaCombined(): { value: number; source: string; confidence: Confidence } | null {
  const m = mpgSpec && typeof mpgSpec.value === 'string' ? /(\d+(?:\.\d+)?)\s*combined/.exec(mpgSpec.value) : null;
  return m && mpgSpec ? { value: Number(m[1]), source: mpgSpec.source, confidence: mpgSpec.confidence } : null;
}

export function estimate(i: CostInputs, loggedMpg: number | null, schedule: ScheduledService[] = SCHEDULE, sourcedPrices: Record<string, SourcedValue<number>> = SOURCED_SERVICE_PRICES): CostEstimate {
  const { annualMiles: mi, years } = i;
  if (!mi || !years) return { ready: false, lines: [], notDue: [], perYear: 0, total: 0, perMile: null, unpriced: 0, atLeast: false };
  const lines: CostLine[] = [];
  const notDue: ScheduledService[] = [];
  for (const s of schedule) {
    const times = timesDue(s, mi, years);
    if (times === 0) { notDue.push(s); continue; }
    const sp = sourcedPrices[s.id];
    const user = i.servicePrices[s.id] ?? null;
    const unit = sp && sp.value !== null ? sp.value : user;
    const origin: Origin | null = sp && sp.value !== null ? 'sourced' : user !== null ? 'user' : null;
    lines.push({ id: s.id, kind: 'service', item: s.item, times, unitPrice: unit, perYear: unit === null ? null : (unit * times) / years, priceOrigin: origin,
      source: sp && sp.value !== null ? sp.source : s.source, confidence: sp && sp.value !== null ? sp.confidence : s.confidence });
  }
  const epa = epaCombined();
  const mpg = loggedMpg && loggedMpg > 0 ? { value: loggedMpg, origin: 'user' as const } : epa ? { value: epa.value, origin: 'sourced' as const, source: epa.source, confidence: epa.confidence } : null;
  const fuel = mpg && i.fuelPrice ? (mi / mpg.value) * i.fuelPrice : null;
  lines.push({ id: 'fuel', kind: 'fuel', perYear: fuel, priceOrigin: fuel === null ? null : mpg?.origin === 'sourced' ? 'mixed' : 'user', mpg, source: mpg?.source, confidence: mpg?.confidence });
  lines.push({ id: 'insurance', kind: 'insurance', perYear: i.insurance, priceOrigin: i.insurance === null ? null : 'user' });
  const tires = i.tireSet && i.tireLife ? (mi / i.tireLife) * i.tireSet : null;
  lines.push({ id: 'tires', kind: 'tires', perYear: tires, priceOrigin: tires === null ? null : 'user' });
  const perYear = lines.reduce((a, l) => a + (l.perYear ?? 0), 0);
  const unpriced = lines.filter((l) => l.perYear === null).length;
  return { ready: true, lines, notDue, perYear, total: perYear * years, perMile: perYear / mi, unpriced, atLeast: unpriced > 0 };
}

/** One sourced market data point for the value comparison. */
export interface ValuePoint { id: string; kind: 'stat' | 'auctions'; label: string; value: number; period?: string; n?: number; source?: string; confidence?: Confidence; diff: number | null }

/**
 * Sourced market data points for a model year: published medians (MarketStat) as-is, plus the median of the
 * sourced sold auction results (outliers excluded) with its count. `diff` = point − purchase price (user).
 */
export function valuePoints(year: ModelYear | null, purchase: number | null, stats: MarketStat[] = marketStats, results: AuctionResult[] = auctionResults): ValuePoint[] {
  if (year === null) return [];
  const d = (v: number) => (purchase === null ? null : v - purchase);
  const out: ValuePoint[] = stats.filter((s) => s.year === year && s.value !== null && s.kind !== 'estimate')
    .map((s) => ({ id: s.id, kind: 'stat' as const, label: s.label, value: s.value as number, period: s.period, n: s.sampleSize ?? undefined, source: s.source, confidence: s.confidence, diff: d(s.value as number) }));
  const sold = priced(results.filter((r) => r.year === year && !r.outlier));
  const m = median(sold.map((r) => r.price));
  if (m !== null) out.push({ id: `auctions-${year}`, kind: 'auctions', label: '', value: m, n: sold.length, diff: d(m) });
  return out;
}

export const yearOf = (y: string): ModelYear | null => (y === '2020' || y === '2021' || y === '2022' ? (Number(y) as ModelYear) : null);

/** What the owner's own logs record for this car (all user data). */
export interface LoggedCosts { fuel: number; service: number; mods: number; total: number; miles: number; perMile: number | null; mpg: number | null; fills: number; serviceEntries: number; modEntries: number; trackSessions: number }
export function loggedCosts(fills: FillUp[], service: LogEntry[], mods: LogEntry[], trackSessions: number): LoggedCosts {
  const o = ownershipCost(fills, service, mods);
  return { ...o, mpg: fuelSummary(fills).avgMpg, fills: fills.length, serviceEntries: service.length, modEntries: mods.length, trackSessions };
}
