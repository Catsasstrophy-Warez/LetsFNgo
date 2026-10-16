import { load } from './storage';
import { normFill, normList } from './validate';
import type { LogEntry } from './garage';

export type FuelType = '93' | 'E85' | 'blend';
/** A fill-up. Stored in imperial units (miles, US gallons, $/gal). */
export interface FillUp { id: string; date: string; odometer: number; gallons: number; price: number; fuel: FuelType; /** Ethanol % for blends. */ blend: number | null; full: boolean; notes: string; /** Owning car; missing = car #1. */ carId?: string }

export const FUEL_KEY = 'gt500.fuel.v1';
export const loadFuel = (): FillUp[] => normList(load<unknown>(FUEL_KEY, []), normFill);

export interface FuelPoint { date: string; odometer: number; miles: number; gallons: number; cost: number; mpg: number; costPerMile: number }

const byOdo = (a: FillUp, b: FillUp) => a.odometer - b.odometer || a.date.localeCompare(b.date);

/**
 * Full-to-full mpg. Each interval starts at a full fill and ends at the next full fill; gallons and cost of
 * any partial fills in between count toward that interval. The first full fill only sets the baseline.
 */
export function fuelIntervals(fills: FillUp[]): FuelPoint[] {
  const sorted = [...fills].filter((f) => f.odometer >= 0 && f.gallons > 0).sort(byOdo);
  const out: FuelPoint[] = [];
  let start: FillUp | null = null;
  let gal = 0, cost = 0;
  for (const f of sorted) {
    if (start) { gal += f.gallons; cost += f.gallons * f.price; }
    if (f.full) {
      if (start && gal > 0 && f.odometer > start.odometer) {
        const miles = f.odometer - start.odometer;
        out.push({ date: f.date, odometer: f.odometer, miles, gallons: gal, cost, mpg: miles / gal, costPerMile: cost / miles });
      }
      start = f; gal = 0; cost = 0;
    }
  }
  return out;
}

export interface FuelSummary { fills: number; gallons: number; spend: number; avgMpg: number | null; costPerMile: number | null; miles: number }

export function fuelSummary(fills: FillUp[]): FuelSummary {
  const iv = fuelIntervals(fills);
  const miles = iv.reduce((a, x) => a + x.miles, 0);
  const ivGal = iv.reduce((a, x) => a + x.gallons, 0);
  const ivCost = iv.reduce((a, x) => a + x.cost, 0);
  return {
    fills: fills.length, gallons: fills.reduce((a, f) => a + f.gallons, 0), spend: fills.reduce((a, f) => a + f.gallons * f.price, 0),
    avgMpg: miles && ivGal ? miles / ivGal : null, costPerMile: miles ? ivCost / miles : null, miles,
  };
}

/** "$1,234.50", "1234" → 1234.5; anything else → 0 (log costs are free text). */
export const parseMoney = (s: string | undefined) => { const n = Number(String(s ?? '').replace(/[$,\s]/g, '')); return Number.isFinite(n) && n > 0 ? n : 0; };

export interface OwnershipCost { fuel: number; service: number; mods: number; total: number; miles: number; perMile: number | null }

/** Fuel + service log + mods log spend. Per-mile uses the odometer span covered by the fuel log. */
export function ownershipCost(fills: FillUp[], service: LogEntry[], mods: LogEntry[]): OwnershipCost {
  const fuel = fills.reduce((a, f) => a + f.gallons * f.price, 0);
  const s = service.reduce((a, e) => a + parseMoney(e.cost), 0);
  const m = mods.reduce((a, e) => a + parseMoney(e.cost), 0);
  const odos = fills.map((f) => f.odometer);
  const miles = odos.length >= 2 ? Math.max(...odos) - Math.min(...odos) : 0;
  const total = fuel + s + m;
  return { fuel, service: s, mods: m, total, miles, perMile: miles > 0 ? total / miles : null };
}
