/**
 * Strict normalizers for everything kept in localStorage or imported from a backup.
 * Each rebuilds the object from an allow-list of known keys and returns null if any present field
 * has the wrong type, so nothing unexpected can reach React as a child or be re-exported.
 */
import { DEFAULT_REMINDERS, EMPTY_GARAGE, type GarageState, type LogEntry, type Plan, type Reminder, type TrackSession } from './garage';
import type { GpsRun, Timeslip } from './drag';
import type { FillUp } from './fuel';

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const BAD = Symbol('bad');
/** Optional string: undefined → default; non-string → BAD. */
const str = (v: unknown, d = ''): string | typeof BAD => (v === undefined || v === null ? d : typeof v === 'string' ? v : BAD);
const req = (v: unknown): string | typeof BAD => (typeof v === 'string' ? v : BAD);
/** Optional finite number or null. */
const num = (v: unknown): number | null | typeof BAD => (v === undefined || v === null ? null : typeof v === 'number' && Number.isFinite(v) ? v : BAD);
const reqNum = (v: unknown): number | typeof BAD => (typeof v === 'number' && Number.isFinite(v) ? v : BAD);

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
  return t && pressures ? { ...t, pressures } : null;
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
  return s && weather ? { ...s, weather: { ...weather, pressureIsStation: w.pressureIsStation === true }, mods: [...((v.mods as string[] | undefined) ?? [])], ...(gps ? { gps } : {}) } : null;
}

export function normFill(v: unknown): FillUp | null {
  if (!isObj(v)) return null;
  if (v.fuel !== '93' && v.fuel !== 'E85' && v.fuel !== 'blend') return null;
  if (typeof v.full !== 'boolean') return null;
  return build<FillUp>({ id: req(v.id), date: req(v.date), odometer: reqNum(v.odometer), gallons: reqNum(v.gallons), price: reqNum(v.price), fuel: v.fuel, blend: num(v.blend), full: v.full, notes: str(v.notes) });
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
