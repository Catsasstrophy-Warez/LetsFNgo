import { load } from './storage';
import { normDyno, normList } from './validate';
import { satVaporPressure, stationPressure } from './drag';

export type DynoType = 'dynojet' | 'mustang' | 'hub' | 'other';
export type Correction = 'sae' | 'std' | 'uncorrected';
export const DYNO_TYPES: [DynoType, string][] = [['dynojet', 'Dynojet (inertia)'], ['mustang', 'Mustang (load-bearing)'], ['hub', 'Hub dyno'], ['other', 'Other']];
export const CORRECTIONS: [Correction, string][] = [['sae', 'SAE J1349'], ['std', 'STD (SAE J607)'], ['uncorrected', 'Uncorrected']];

/** One curve sample. Power in whp, torque in lb-ft at the wheels. */
export interface CurvePoint { rpm: number; hp: number | null; tq: number | null }

/** A dyno pull. Stored imperial: whp, lb-ft, °F, inHg, ft. */
export interface DynoPull {
  id: string; date: string; shop: string;
  whp: number; wtq: number | null;
  dynoType: DynoType; correction: Correction;
  weather: { tempF: number | null; pressureInHg: number | null; humidity: number | null; elevationFt: number | null; pressureIsStation: boolean };
  mods: string[]; curve: CurvePoint[]; notes: string;
  /** Owning car (multi-car Garage); missing = car #1. */
  carId?: string;
}

export const DYNO_KEY = 'gt500.dyno.v1';
export const loadDyno = (): DynoPull[] => normList(load<unknown>(DYNO_KEY, []), normDyno);
export const MAX_CURVE_POINTS = 400;

export interface Air { tempF: number; pressureInHg: number; humidity: number; elevationFt?: number; pressureIsStation?: boolean }

/** Dry-air pressure in hPa: station pressure minus water-vapor partial pressure. */
export function dryPressureHpa(a: Air): number | null {
  if (![a.tempF, a.pressureInHg, a.humidity].every(Number.isFinite) || a.pressureInHg <= 0 || a.humidity < 0 || a.humidity > 100) return null;
  const tC = (a.tempF - 32) * 5 / 9;
  const hpa = a.pressureInHg * 33.8638866667;
  const p = a.pressureIsStation ? hpa : stationPressure(hpa, (a.elevationFt ?? 0) * 0.3048);
  const pd = p - (a.humidity / 100) * satVaporPressure(tC);
  return pd > 0 ? pd : null;
}

/**
 * SAE J1349 (1990/2004 form): CF = 1.18 × (990 / Pd[hPa]) × √((T[°C] + 273) / 298) − 0.18.
 * Reference: 25 °C, 99 kPa dry air; the 1.18/−0.18 terms assume 85% mechanical efficiency.
 */
export function saeFactor(a: Air): number | null {
  const pd = dryPressureHpa(a);
  if (pd === null) return null;
  const tC = (a.tempF - 32) * 5 / 9;
  return 1.18 * (990 / pd) * Math.sqrt((tC + 273) / 298) - 0.18;
}

/** STD (SAE J607): CF = (29.92 / Pd[inHg]) × √((T[°F] + 460) / 520). Reference: 60 °F, 29.92 inHg dry. */
export function stdFactor(a: Air): number | null {
  const pd = dryPressureHpa(a);
  if (pd === null) return null;
  return (29.92 / (pd / 33.8638866667)) * Math.sqrt((a.tempF + 460) / 520);
}

const factor = (c: Correction, a: Air) => (c === 'uncorrected' ? 1 : c === 'sae' ? saeFactor(a) : stdFactor(a));

/** Convert a figure between corrections using the run's weather. Null if the weather is incomplete. */
export function convertCorrection(value: number, from: Correction, to: Correction, a: Air | null): number | null {
  if (from === to) return value;
  if (!a) return null;
  const f = factor(from, a), t = factor(to, a);
  return f && t ? (value / f) * t : null;
}

export const airOf = (w: DynoPull['weather']): Air | null =>
  w.tempF !== null && w.pressureInHg !== null ? { tempF: w.tempF, pressureInHg: w.pressureInHg, humidity: w.humidity ?? 0, elevationFt: w.elevationFt ?? 0, pressureIsStation: w.pressureIsStation } : null;

/**
 * Parse pasted curve text: one "rpm, hp, tq" row per line (comma, tab or space separated; "-" for blank).
 * Returns points sorted by rpm, or the first error.
 */
export function parseCurve(text: string): { ok: true; points: CurvePoint[] } | { ok: false; error: string } {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !/^[a-z#]/i.test(l));
  if (lines.length > MAX_CURVE_POINTS) return { ok: false, error: `At most ${MAX_CURVE_POINTS} rows.` };
  const pts: CurvePoint[] = [];
  for (const [i, l] of lines.entries()) {
    const cells = l.split(/[,\t;]\s*|\s+/).filter(Boolean);
    const n = (s: string | undefined) => (s === undefined || s === '-' ? null : Number(s));
    const [rpm, hp, tq] = [n(cells[0]), n(cells[1]), n(cells[2])];
    if (rpm === null || !Number.isFinite(rpm) || rpm <= 0 || rpm > 12000) return { ok: false, error: `Row ${i + 1}: rpm must be 1–12,000.` };
    if ((hp !== null && (!Number.isFinite(hp) || hp < 0 || hp > 5000)) || (tq !== null && (!Number.isFinite(tq) || tq < 0 || tq > 5000))) return { ok: false, error: `Row ${i + 1}: hp/tq must be 0–5,000.` };
    if (hp === null && tq === null) return { ok: false, error: `Row ${i + 1}: needs hp or torque.` };
    pts.push({ rpm, hp, tq });
  }
  return { ok: true, points: pts.sort((a, b) => a.rpm - b.rpm) };
}

/** Peak values of a pull, from the curve when present, else the entered peaks. */
export function peaks(p: DynoPull): { hp: number; tq: number | null } {
  const hp = Math.max(p.whp, ...p.curve.map((c) => c.hp ?? 0));
  const tqs = p.curve.map((c) => c.tq).filter((x): x is number => x !== null);
  return { hp, tq: tqs.length ? Math.max(p.wtq ?? 0, ...tqs) : p.wtq };
}
