/**
 * Strict normalizers for everything kept in localStorage or imported from a backup.
 * Each rebuilds the object from an allow-list of known keys and returns null if any present field
 * has the wrong type, so nothing unexpected can reach React as a child or be re-exported.
 */
import { DEFAULT_REMINDERS, EMPTY_GARAGE, MAX_CARS, type Car, type CarStore, type GarageState, type LogEntry, type Plan, type Reminder, type TrackSession } from './garage';
import type { GpsRun, Timeslip } from './drag';
import type { FillUp } from './fuel';
import { MAX_CURVE_POINTS, type CurvePoint, type DynoPull } from './dyno';

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const BAD = Symbol('bad');
/** Optional string: undefined → default; non-string → BAD. */
const str = (v: unknown, d = ''): string | typeof BAD => (v === undefined || v === null ? d : typeof v === 'string' ? v : BAD);
const req = (v: unknown): string | typeof BAD => (typeof v === 'string' ? v : BAD);
/** Optional finite number or null. */
const num = (v: unknown): number | null | typeof BAD => (v === undefined || v === null ? null : typeof v === 'number' && Number.isFinite(v) ? v : BAD);
const reqNum = (v: unknown): number | typeof BAD => (typeof v === 'number' && Number.isFinite(v) ? v : BAD);

/** Optional owning-car id: absent → {}, valid → { carId }, anything else → null. */
function carField(v: Obj): { carId?: string } | null {
  if (v.carId === undefined || v.carId === null || v.carId === '') return {};
  return typeof v.carId === 'string' && /^[A-Za-z0-9_-]{1,40}$/.test(v.carId) ? { carId: v.carId } : null;
}

function build<T>(fields: Record<string, unknown>): T | null {
  return Object.values(fields).some((x) => x === BAD) ? null : (fields as T);
}

/** Normalize a list: invalid items are dropped (for loaders). */
export function normList<T>(v: unknown, f: (x: unknown) => T | null): T[] {
  return Array.isArray(v) ? v.map(f).filter((x): x is T => x !== null) : [];
}

export function normLog(v: unknown): LogEntry | null {
  if (!isObj(v)) return null;
  return build<LogEntry>({ id: req(v.id), date: req(v.date), title: req(v.title), notes: str(v.notes), miles: str(v.miles), cost: str(v.cost) });
}

export function normReminder(v: unknown): Reminder | null {
  if (!isObj(v)) return null;
  return build<Reminder>({ id: req(v.id), item: req(v.item), everyMiles: num(v.everyMiles), everyMonths: num(v.everyMonths), lastMiles: num(v.lastMiles), lastDate: str(v.lastDate) });
}

/** Garage: top-level strings must be strings; log/reminder arrays must contain only valid entries. */
export function normGarage(v: unknown): GarageState | null {
  if (!isObj(v)) return null;
  const lists = { mods: v.mods ?? [], service: v.service ?? [], reminders: v.reminders ?? DEFAULT_REMINDERS };
  if (!Array.isArray(lists.mods) || !Array.isArray(lists.service) || !Array.isArray(lists.reminders)) return null;
  const mods = lists.mods.map(normLog), service = lists.service.map(normLog), reminders = lists.reminders.map(normReminder);
  if ([...mods, ...service, ...reminders].some((x) => x === null)) return null;
  const g = build<Omit<GarageState, 'mods' | 'service' | 'reminders'>>({
    vin: str(v.vin, EMPTY_GARAGE.vin), year: str(v.year), color: str(v.color), nickname: str(v.nickname), odometer: str(v.odometer),
  });
  return g ? { ...g, mods: mods as LogEntry[], service: service as LogEntry[], reminders: reminders as Reminder[] } : null;
}

/** Multi-car store: 1–MAX_CARS cars with unique ids; an unknown active id falls back to the first car. */
export function normCarStore(v: unknown): CarStore | null {
  if (!isObj(v) || !Array.isArray(v.cars) || v.cars.length < 1 || v.cars.length > MAX_CARS) return null;
  const cars: Car[] = [];
  for (const x of v.cars) {
    if (!isObj(x) || typeof x.id !== 'string' || !/^[A-Za-z0-9_-]{1,40}$/.test(x.id) || cars.some((c) => c.id === x.id)) return null;
    const g = normGarage(x);
    if (!g) return null;
    cars.push({ ...g, id: x.id });
  }
  const active = typeof v.active === 'string' && cars.some((c) => c.id === v.active) ? v.active : cars[0].id;
  return { active, cars };
}

export function normPlan(v: unknown): Plan | null {
  if (!isObj(v) || !Array.isArray(v.modIds) || !v.modIds.every((x) => typeof x === 'string')) return null;
  const p = build<Omit<Plan, 'modIds'>>({ id: req(v.id), name: req(v.name), created: str(v.created) });
  return p ? { ...p, modIds: [...(v.modIds as string[])] } : null;
}

export function normTrack(v: unknown): TrackSession | null {
  if (!isObj(v)) return null;
  const pr = v.pressures ?? {};
  if (!isObj(pr)) return null;
  const pressures = build<TrackSession['pressures']>({ fl: str(pr.fl), fr: str(pr.fr), rl: str(pr.rl), rr: str(pr.rr) });
  const t = build<Omit<TrackSession, 'pressures'>>({ id: req(v.id), date: req(v.date), track: req(v.track), conditions: str(v.conditions), airTemp: str(v.airTemp), laps: req(v.laps), notes: str(v.notes) });
  const c = carField(v);
  return t && pressures && c ? { ...t, pressures, ...c } : null;
}

export function normSlip(v: unknown): Timeslip | null {
  if (!isObj(v)) return null;
  const w = v.weather ?? {};
  if (!isObj(w)) return null;
  if (v.mods !== undefined && !(Array.isArray(v.mods) && v.mods.every((x) => typeof x === 'string'))) return null;
  if (w.pressureIsStation !== undefined && typeof w.pressureIsStation !== 'boolean') return null;
  const weather = build<Omit<Timeslip['weather'], 'pressureIsStation'>>({ tempF: num(w.tempF), pressureInHg: num(w.pressureInHg), humidity: num(w.humidity), elevationFt: num(w.elevationFt) });
  const s = build<Omit<Timeslip, 'weather' | 'mods'>>({
    id: req(v.id), date: req(v.date), track: str(v.track), rt: num(v.rt), sixty: num(v.sixty), threeThirty: num(v.threeThirty),
    eighthEt: num(v.eighthEt), eighthMph: num(v.eighthMph), quarterEt: num(v.quarterEt), quarterMph: num(v.quarterMph), da: num(v.da), notes: str(v.notes),
  });
  let gps: Timeslip['gps'];
  if (v.gps !== undefined) {
    const g = v.gps;
    if (!isObj(g) || (g.kind !== '0-60' && g.kind !== '60-130' && g.kind !== 'quarter')) return null;
    const b = build<Omit<GpsRun, 'kind'>>({ seconds: reqNum(g.seconds), trapMph: num(g.trapMph), accuracyM: reqNum(g.accuracyM) });
    if (!b || b.seconds <= 0) return null;
    gps = { kind: g.kind, ...b };
  }
  const c = carField(v);
  return s && weather && c ? { ...s, ...c, weather: { ...weather, pressureIsStation: w.pressureIsStation === true }, mods: [...((v.mods as string[] | undefined) ?? [])], ...(gps ? { gps } : {}) } : null;
}

export function normFill(v: unknown): FillUp | null {
  if (!isObj(v)) return null;
  if (v.fuel !== '93' && v.fuel !== 'E85' && v.fuel !== 'blend') return null;
  if (typeof v.full !== 'boolean') return null;
  const c = carField(v);
  const f = build<FillUp>({ id: req(v.id), date: req(v.date), odometer: reqNum(v.odometer), gallons: reqNum(v.gallons), price: reqNum(v.price), fuel: v.fuel, blend: num(v.blend), full: v.full, notes: str(v.notes) });
  return f && c ? { ...f, ...c } : null;
}

export interface QuizScore { answered: number; correct: number; bestStreak: number; streak: number }
export const EMPTY_SCORE: QuizScore = { answered: 0, correct: 0, bestStreak: 0, streak: 0 };
export function normScore(v: unknown): QuizScore {
  if (!isObj(v)) return { ...EMPTY_SCORE };
  const n = (x: unknown) => (typeof x === 'number' && Number.isInteger(x) && x >= 0 ? x : 0);
  const s = { answered: n(v.answered), correct: n(v.correct), bestStreak: n(v.bestStreak), streak: n(v.streak) };
  return s.correct > s.answered ? { ...EMPTY_SCORE } : s;
}

/** First-run intro state. */
export interface Onboarding { done: boolean; completed: string }
export const DEFAULT_ONBOARDING: Onboarding = { done: false, completed: '' };
export function normOnboarding(v: unknown): Onboarding | null {
  if (!isObj(v) || typeof v.done !== 'boolean') return null;
  const c = str(v.completed);
  return c === BAD ? null : { done: v.done, completed: c };
}

const DYNO_TYPES = ['dynojet', 'mustang', 'hub', 'other'] as const;
const CORRS = ['sae', 'std', 'uncorrected'] as const;
const inRange = (x: number | null, lo: number, hi: number) => x === null || (x >= lo && x <= hi);

/** Dyno pull: enums allow-listed, power/torque/rpm range-checked, curve capped. */
export function normDyno(v: unknown): DynoPull | null {
  if (!isObj(v)) return null;
  if (!DYNO_TYPES.includes(v.dynoType as never) || !CORRS.includes(v.correction as never)) return null;
  const w = v.weather ?? {};
  if (!isObj(w)) return null;
  if (w.pressureIsStation !== undefined && typeof w.pressureIsStation !== 'boolean') return null;
  if (v.mods !== undefined && !(Array.isArray(v.mods) && v.mods.every((x) => typeof x === 'string'))) return null;
  const rawCurve = v.curve ?? [];
  if (!Array.isArray(rawCurve) || rawCurve.length > MAX_CURVE_POINTS) return null;
  const curve: CurvePoint[] = [];
  for (const c of rawCurve) {
    if (!isObj(c)) return null;
    const p = build<CurvePoint>({ rpm: reqNum(c.rpm), hp: num(c.hp), tq: num(c.tq) });
    if (!p || p.rpm <= 0 || p.rpm > 12000 || !inRange(p.hp, 0, 5000) || !inRange(p.tq, 0, 5000)) return null;
    curve.push(p);
  }
  const weather = build<Omit<DynoPull['weather'], 'pressureIsStation'>>({ tempF: num(w.tempF), pressureInHg: num(w.pressureInHg), humidity: num(w.humidity), elevationFt: num(w.elevationFt) });
  if (weather && (!inRange(weather.humidity, 0, 100) || !inRange(weather.pressureInHg, 1, 40))) return null;
  const d = build<Omit<DynoPull, 'weather' | 'mods' | 'curve' | 'dynoType' | 'correction'>>({
    id: req(v.id), date: req(v.date), shop: str(v.shop), whp: reqNum(v.whp), wtq: num(v.wtq), notes: str(v.notes),
  });
  const c = carField(v);
  if (!c || !d || !weather || d.whp <= 0 || d.whp > 5000 || !inRange(d.wtq, 0, 5000)) return null;
  return { ...d, ...c, dynoType: v.dynoType as DynoPull['dynoType'], correction: v.correction as DynoPull['correction'], weather: { ...weather, pressureIsStation: w.pressureIsStation === true }, mods: [...((v.mods as string[] | undefined) ?? [])], curve: curve.sort((a, b) => a.rpm - b.rpm) };
}

/** Local notification preference and which reminder due-keys were already announced. */
export interface NotifyPrefs { enabled: boolean; sent: Record<string, string> }
export const DEFAULT_NOTIFY: NotifyPrefs = { enabled: false, sent: {} };
export function normNotify(v: unknown): NotifyPrefs | null {
  if (!isObj(v) || typeof v.enabled !== 'boolean') return null;
  const s = v.sent ?? {};
  if (!isObj(s)) return null;
  const sent: Record<string, string> = {};
  for (const [k, x] of Object.entries(s).slice(0, 200)) {
    if (typeof x !== 'string') return null;
    // Keys come from imported JSON: never let one reach an object's prototype slot.
    if (k === '__proto__' || k === 'constructor' || k === 'prototype' || k.length > 100 || x.length > 200) continue;
    sent[k] = x;
  }
  return { enabled: v.enabled, sent };
}

/** Home dashboard layout: card order and hidden cards, unknown ids dropped, missing ids appended. */
export interface DashLayout { order: string[]; hidden: string[] }
export function normDash(v: unknown, known: readonly string[]): DashLayout | null {
  if (!isObj(v) || !Array.isArray(v.order) || !Array.isArray(v.hidden)) return null;
  if (![...v.order, ...v.hidden].every((x) => typeof x === 'string')) return null;
  const order = [...new Set((v.order as string[]).filter((x) => known.includes(x)))];
  for (const k of known) if (!order.includes(k)) order.push(k);
  return { order, hidden: [...new Set((v.hidden as string[]).filter((x) => known.includes(x)))] };
}
