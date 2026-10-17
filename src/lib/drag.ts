import { performance } from '../data/performance';
import type { PerformanceRecord } from '../data/types';
import { load } from './storage';
import { normList, normSlip } from './validate';

/** One drag-strip timeslip. Numbers are stored in imperial units (s, mph, °F, inHg, ft). */
export interface Timeslip {
  id: string; date: string; track: string;
  rt: number | null; sixty: number | null; threeThirty: number | null;
  eighthEt: number | null; eighthMph: number | null; quarterEt: number | null; quarterMph: number | null;
  /** Density altitude in ft (entered or calculated). */
  da: number | null;
  weather: { tempF: number | null; pressureInHg: number | null; humidity: number | null; elevationFt: number | null; pressureIsStation: boolean };
  /** Garage mods at the time of the pass. */
  mods: string[];
  notes: string;
  /** Present only for runs timed by the GPS meter. These are approximate and excluded from strip stats. */
  gps?: GpsRun;
  /** Owning car (multi-car Garage); missing = car #1. */
  carId?: string;
}

/** A GPS-meter result saved to the Drag log ("GPS estimate"). */
export interface GpsRun { kind: '0-60' | '60-130' | 'quarter'; seconds: number; trapMph: number | null; accuracyM: number }

export const DRAG_KEY = 'gt500.drag.v1';
export const loadDrag = (): Timeslip[] => normList(load<unknown>(DRAG_KEY, []), normSlip);

// ISA constants
const T0 = 288.15; // K
const L = 0.0065; // K/m
const RD = 287.05; // J/(kg·K)
const G = 9.80665;
const RHO0 = 1.225; // kg/m³
const EXP = (L * RD) / (G - L * RD); // ≈ 0.234969
const FT = 0.3048;

/** Saturation vapor pressure (hPa), Tetens/Magnus form used by NWS. */
export const satVaporPressure = (tC: number) => 6.1078 * Math.pow(10, (7.5 * tC) / (237.3 + tC));

/** Station (absolute) pressure in hPa from an altimeter setting (sea-level corrected) and elevation in m. */
export function stationPressure(altimeterHpa: number, elevM: number): number {
  return altimeterHpa * Math.pow((T0 - L * elevM) / T0, 5.25588);
}

export interface DaInput { tempF: number; pressureInHg: number; humidity: number; elevationFt: number; pressureIsStation?: boolean }
export interface DaResult { daFt: number; densityRatio: number; stationInHg: number; vaporHpa: number; virtualTempF: number }

/**
 * Density altitude by the standard method: virtual temperature from humidity, air density
 * from station pressure, then the ISA altitude with that density.
 * `pressureInHg` is the corrected barometer/altimeter setting (what weather reports show) unless
 * `pressureIsStation` is true, in which case it is the raw station pressure and elevation is not applied.
 */
export function densityAltitude(i: DaInput): DaResult | null {
  const { tempF, pressureInHg, humidity, elevationFt } = i;
  if (![tempF, pressureInHg, humidity, elevationFt].every(Number.isFinite) || pressureInHg <= 0 || humidity < 0 || humidity > 100) return null;
  const tC = (tempF - 32) * 5 / 9;
  const tK = tC + 273.15;
  const pAlt = pressureInHg * 33.8638866667;
  const p = i.pressureIsStation ? pAlt : stationPressure(pAlt, elevationFt * FT);
  const e = (humidity / 100) * satVaporPressure(tC);
  const tv = tK / (1 - (e / p) * (1 - 0.622));
  const rho = (p * 100) / (RD * tv);
  const sigma = rho / RHO0;
  const daM = (T0 / L) * (1 - Math.pow(sigma, EXP));
  return { daFt: daM / FT, densityRatio: sigma, stationInHg: p / 33.8638866667, vaporHpa: e, virtualTempF: (tv - 273.15) * 9 / 5 + 32 };
}

/** Air density ratio (vs. ISA sea level) for a density altitude in ft. */
export const densityRatioAt = (daFt: number) => Math.pow(1 - (daFt * FT * L) / T0, 1 / EXP);

/**
 * ESTIMATE of what a pass would have run at 0 ft density altitude. Assumes power scales with air
 * density and ET ∝ power^(−1/3) (the same cube-root relation as the Hale/Fox rules of thumb).
 * Not an NHRA/SAE correction — traction, boost control and the tune are ignored.
 */
export function correctToSeaLevel(et: number, mph: number | null, daFt: number): { et: number; mph: number | null } | null {
  if (!(et > 0) || !Number.isFinite(daFt)) return null;
  const s = densityRatioAt(daFt);
  if (!(s > 0)) return null;
  const k = Math.cbrt(s);
  return { et: et * k, mph: mph !== null && mph > 0 ? mph / k : null };
}

export interface DragStats {
  count: number; bestEt: number | null; bestMph: number | null; bestSixty: number | null; bestRt: number | null;
  meanEt: number | null; sdEt: number | null; spreadEt: number | null;
}

const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

/** Best values and consistency (sample standard deviation and spread of ¼-mile ET). */
export function dragStats(all: Timeslip[]): DragStats {
  const slips = all.filter((s) => !s.gps);
  const pick = (f: (s: Timeslip) => number | null) => slips.map(f).filter((x): x is number => x !== null && x > 0);
  const ets = pick((s) => s.quarterEt);
  const min = (xs: number[]) => (xs.length ? Math.min(...xs) : null);
  const rts = slips.map((s) => s.rt).filter((x): x is number => x !== null && x >= 0);
  const m = ets.length ? mean(ets) : null;
  const sd = ets.length >= 2 && m !== null ? Math.sqrt(ets.reduce((a, x) => a + (x - m) ** 2, 0) / (ets.length - 1)) : null;
  return {
    count: slips.length, bestEt: min(ets), bestMph: pick((s) => s.quarterMph).reduce<number | null>((a, x) => (a === null || x > a ? x : a), null),
    bestSixty: min(pick((s) => s.sixty)), bestRt: min(rts), meanEt: m, sdEt: sd, spreadEt: ets.length ? Math.max(...ets) - Math.min(...ets) : null,
  };
}

export interface StockPass { record: PerformanceRecord; et: number; mph: number | null }

/** Parse "10.61 s @ 133 mph" style results. */
export function parsePass(result: string): { et: number; mph: number | null } | null {
  const m = /(\d+\.\d+)\s*s(?:\s*@\s*(\d+(?:\.\d+)?)\s*mph)?/.exec(result);
  if (!m) return null;
  const qm = /¼\s*(\d+\.\d+)/.exec(result);
  return { et: Number(qm ? qm[1] : m[1]), mph: m[2] ? Number(m[2]) : null };
}

/** Sourced stock (unmodified) quarter-mile results, confirmed or reported only. */
export function stockPasses(): StockPass[] {
  return performance
    .filter((p) => (p.car === 'stock' || p.car === 'stock (CFTP)') && p.confidence !== 'unverified' && (p.category === 'quarter-mile' || /¼/.test(p.result)))
    .map((record) => ({ record, p: parsePass(record.result) }))
    .filter((x): x is { record: PerformanceRecord; p: { et: number; mph: number | null } } => x.p !== null)
    .map(({ record, p }) => ({ record, ...p }));
}
