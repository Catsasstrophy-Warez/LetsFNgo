/**
 * Cost of ownership inputs, stored per Garage car. Every number here is typed by the owner; nothing is defaulted
 * or invented (an empty field is null). This module imports no data so the backup chunk stays small.
 * In backups since schema 11.
 */
import { load, save } from './storage';

export const COST_KEY = 'gt500.cost.v1';
export const MAX_COST_CARS = 12;
export const MAX_SERVICE_PRICES = 40;

export interface CostInputs {
  /** Miles driven per year. */
  annualMiles: number | null;
  /** Years of ownership to estimate over. */
  years: number | null;
  /** Fuel price, USD per US gallon. */
  fuelPrice: number | null;
  /** Insurance, USD per year. */
  insurance: number | null;
  /** One set of tires, USD. */
  tireSet: number | null;
  /** Miles one set of tires lasts. */
  tireLife: number | null;
  /** What the owner paid for the car, USD. */
  purchasePrice: number | null;
  /** Owner's own cost per scheduled service, keyed by service id. */
  servicePrices: Record<string, number>;
}
export interface CostStore { cars: Record<string, CostInputs> }

export const EMPTY_INPUTS: CostInputs = { annualMiles: null, years: null, fuelPrice: null, insurance: null, tireSet: null, tireLife: null, purchasePrice: null, servicePrices: {} };
export const emptyInputs = (): CostInputs => ({ ...EMPTY_INPUTS, servicePrices: {} });
const NUM_FIELDS = ['annualMiles', 'years', 'fuelPrice', 'insurance', 'tireSet', 'tireLife', 'purchasePrice'] as const;
const ID = /^[a-z0-9-]{1,40}$/i;
const MAX = 1e8;

/** A finite positive number below a sane cap, else null. */
export const posNum = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) && v > 0 && v < MAX ? v : null);

export function normInputs(v: unknown): CostInputs | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const out = emptyInputs();
  for (const k of NUM_FIELDS) out[k] = posNum(o[k]);
  if (o.servicePrices && typeof o.servicePrices === 'object' && !Array.isArray(o.servicePrices)) {
    for (const [k, x] of Object.entries(o.servicePrices as Record<string, unknown>).slice(0, MAX_SERVICE_PRICES)) {
      const n = posNum(x);
      if (ID.test(k) && n !== null) out.servicePrices[k] = n;
    }
  }
  return out;
}

/** Normalize stored/imported state; null when it is not an object with a `cars` object. Bad entries are dropped. */
export function normCost(v: unknown): CostStore | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const c = (v as Record<string, unknown>).cars;
  if (!c || typeof c !== 'object' || Array.isArray(c)) return null;
  const cars: Record<string, CostInputs> = {};
  for (const [id, x] of Object.entries(c as Record<string, unknown>).slice(0, MAX_COST_CARS)) {
    const n = normInputs(x);
    if (ID.test(id) && n) cars[id] = n;
  }
  return { cars };
}

export const loadCost = (): CostStore => normCost(load<unknown>(COST_KEY, null)) ?? { cars: {} };
export const saveCost = (s: CostStore): boolean => save(COST_KEY, normCost(s) ?? { cars: {} });
export const inputsFor = (s: CostStore, carId: string): CostInputs => s.cars[carId] ?? emptyInputs();
/** Replace one car's inputs, keeping the other cars'. */
export const withInputs = (s: CostStore, carId: string, i: CostInputs): CostStore => ({ cars: { ...s.cars, [carId]: i } });
