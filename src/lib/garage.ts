import { load, save } from './storage';
import type { TimingLine, TracePt } from './lapTimer';
import { normCarStore, normGarage, normList, normPlan, normTrack } from './validate';

export interface LogEntry { id: string; date: string; title: string; notes: string; miles?: string; cost?: string }

/** A user-set service reminder. Intervals are the owner's choice — Ford's schedule is not sourced in this app. */
export interface Reminder { id: string; item: string; everyMiles: number | null; everyMonths: number | null; lastMiles: number | null; lastDate: string }

export interface GarageState {
  vin: string; year: string; color: string; nickname: string;
  odometer: string;
  mods: LogEntry[]; service: LogEntry[]; reminders: Reminder[];
}

export interface Plan { id: string; name: string; modIds: string[]; created: string }

export interface TrackSession {
  id: string; date: string; track: string; conditions: string; airTemp: string;
  pressures: { fl: string; fr: string; rl: string; rr: string };
  laps: string; notes: string;
  /** Owning car (multi-car Garage). Missing means the first, migrated car (`DEFAULT_CAR_ID`). */
  carId?: string;
  /** Present when the session was recorded by the GPS lap timer (backup schema v7). */
  gps?: GpsSession;
}

/** One lap timed by GPS. `startMs`/`endMs` are relative to the trace start; accuracy is the worst fix in the lap (m). */
export interface GpsLap { n: number; seconds: number; sectors: number[] | null; accuracyM: number; startMs: number; endMs: number; valid: boolean }
/** GPS provenance of a lap-timer session: the line(s) used, every lap (refused ones flagged) and a capped trace. */
export interface GpsSession { startIso: string; line: TimingLine; sectors: TimingLine[]; laps: GpsLap[]; trace: TracePt[] }

export const KEYS = { garage: 'gt500.garage.v1', cars: 'gt500.cars.v1', plans: 'gt500.plans.v1', track: 'gt500.track.v1' } as const;

export const uid = () => Math.random().toString(36).slice(2, 10);
/** Local calendar date (YYYY-MM-DD), not UTC. */
export const today = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

/**
 * Starter reminders from the 2021 GT500 owner-manual supplement (reported; 2020/2022 unconfirmed — see
 * data/maintenance.ts). Every interval stays editable. Oil uses the maximum; the oil-life monitor may call earlier.
 */
export const DEFAULT_REMINDERS: Reminder[] = [
  { id: 'r-oil', item: 'Engine oil & filter (max; severe use 3,000 mi)', everyMiles: 10000, everyMonths: 12, lastMiles: null, lastDate: '' },
  { id: 'r-brake', item: 'Brake fluid (DOT 4 LV)', everyMiles: null, everyMonths: 36, lastMiles: null, lastDate: '' },
  { id: 'r-cabin', item: 'Cabin air filter', everyMiles: 20000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-dct-top', item: 'DCT side filter + fluid top-off', everyMiles: 20000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-air', item: 'Engine air filter', everyMiles: 30000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-dct', item: 'DCT fluid (XT-14-L) + side filter', everyMiles: 40000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-fuel', item: 'Fuel filter', everyMiles: 50000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-plugs', item: 'Spark plugs', everyMiles: 100000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-diff', item: 'Differential fluid', everyMiles: 150000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-coolant', item: 'Engine coolant (first change)', everyMiles: 200000, everyMonths: 120, lastMiles: null, lastDate: '' },
];

export const EMPTY_GARAGE: GarageState = { vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: DEFAULT_REMINDERS };

/**
 * Multi-car Garage. Every car is a full GarageState plus an id; logs (track, drag, fuel, dyno) link to a car by
 * `carId`. Data from the single-car era (key `gt500.garage.v1`, logs without `carId`) becomes car #1 with id
 * `DEFAULT_CAR_ID`, so nothing has to be rewritten: an entry without `carId` belongs to that car.
 */
export const DEFAULT_CAR_ID = 'car1';
export const MAX_CARS = 12;
export interface Car extends GarageState { id: string }
export interface CarStore { active: string; cars: Car[] }

/** The car a log entry belongs to. */
export const carOf = (e: { carId?: string }): string => e.carId || DEFAULT_CAR_ID;
/** Entries that belong to one car. */
export const forCar = <T extends { carId?: string }>(list: T[], id: string): T[] => list.filter((e) => carOf(e) === id);

/** Store from the legacy single-car key (lossless: every field is kept, the car gets id `car1`). */
export function legacyStore(): CarStore {
  const g = normGarage(load<unknown>(KEYS.garage, null)) ?? { ...EMPTY_GARAGE };
  return { active: DEFAULT_CAR_ID, cars: [{ id: DEFAULT_CAR_ID, ...g }] };
}

// Loaders validate stored JSON and fall back to defaults, so a corrupt or legacy key cannot crash a page.
/** All cars. Reads `gt500.cars.v1`; if it is missing or corrupt, migrates the legacy single-car key. */
export const loadCars = (): CarStore => normCarStore(load<unknown>(KEYS.cars, null)) ?? legacyStore();
export const saveCars = (s: CarStore) => save(KEYS.cars, s);
export const activeCar = (s: CarStore): Car => s.cars.find((c) => c.id === s.active) ?? s.cars[0];
export const activeCarId = (): string => activeCar(loadCars()).id;

/** The active car's Garage (what every single-car page reads). */
export const loadGarage = (): GarageState => { const { id: _id, ...g } = activeCar(loadCars()); void _id; return g; };
/** Replace the active car's Garage, keeping the other cars. */
export function saveGarage(g: GarageState): boolean {
  const s = loadCars();
  const id = activeCar(s).id;
  const { id: _drop, ...clean } = g as GarageState & { id?: string }; void _drop;
  return saveCars({ active: id, cars: s.cars.map((c) => (c.id === id ? { ...clean, id } : c)) });
}

/** Display name: nickname, else "2021 GT500", else "Car 2". */
export function carLabel(c: Pick<Car, 'nickname' | 'year'>, index: number): string {
  return c.nickname.trim() || (c.year ? `${c.year} GT500` : `Car ${index + 1}`);
}

/** Add a car (fresh reminders) and make it active. Returns the new id, or null at the limit / on a failed write. */
export function addCar(init: Partial<GarageState> = {}, s: CarStore = loadCars()): string | null {
  if (s.cars.length >= MAX_CARS) return null;
  let id = uid();
  while (id === DEFAULT_CAR_ID || s.cars.some((c) => c.id === id)) id = uid();
  const car: Car = { ...EMPTY_GARAGE, reminders: DEFAULT_REMINDERS.map((r) => ({ ...r })), mods: [], service: [], ...init, id };
  return saveCars({ active: id, cars: [...s.cars, car] }) ? id : null;
}

export const setActiveCar = (id: string, s: CarStore = loadCars()): boolean =>
  s.cars.some((c) => c.id === id) ? saveCars({ ...s, active: id }) : false;

/** Remove a car (never the last one). The caller also purges that car's log entries (see `purgeCarLogs`). */
export function removeCarFromStore(id: string, s: CarStore): CarStore | null {
  if (s.cars.length <= 1 || !s.cars.some((c) => c.id === id)) return null;
  const cars = s.cars.filter((c) => c.id !== id);
  return { active: s.active === id ? cars[0].id : s.active, cars };
}
export const loadPlans = (): Plan[] => normList(load<unknown>(KEYS.plans, []), normPlan);
export const loadTrack = (): TrackSession[] => normList(load<unknown>(KEYS.track, []), normTrack);
/** Track sessions of the active car. */
export const loadCarTrack = (): TrackSession[] => forCar(loadTrack(), activeCarId());

/** Append an entry to the Garage mods log (used by the build planner). */
export function addModsToGarage(titles: { title: string; notes: string }[]): void {
  const g = loadGarage();
  saveGarage({ ...g, mods: [...g.mods, ...titles.map((t) => ({ id: uid(), date: today(), title: t.title, notes: t.notes, miles: '', cost: '' }))] });
}

export type DueState = 'overdue' | 'soon' | 'ok' | 'unknown';
export interface ReminderStatus { state: DueState; dueMiles: number | null; dueDate: string | null; milesLeft: number | null; daysLeft: number | null }

function addMonths(iso: string, months: number): string {
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(0);
  dt.setUTCFullYear(y, m - 1 + months, 1); // setUTCFullYear, not Date.UTC: Date.UTC maps years 0–99 to 1900–1999
  const last = new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0)).getUTCDate();
  dt.setUTCDate(Math.min(d, last));
  return dt.toISOString().slice(0, 10);
}

const dayDiff = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 86400000);

/** Due state from the last service and current odometer/date. Whichever limit comes first wins. */
export function reminderStatus(r: Reminder, odometer: number | null, now: string, soonMiles = 500, soonDays = 30): ReminderStatus {
  // Zero or negative intervals (typed "-3", "0") mean "no interval", not "already overdue".
  const dueMiles = r.everyMiles && r.everyMiles > 0 && r.lastMiles !== null ? r.lastMiles + r.everyMiles : null;
  const dueDate = r.everyMonths && r.everyMonths > 0 && /^\d{4}-\d{2}-\d{2}$/.test(r.lastDate) ? addMonths(r.lastDate, r.everyMonths) : null;
  const milesLeft = dueMiles !== null && odometer !== null ? dueMiles - odometer : null;
  const daysLeft = dueDate ? dayDiff(now, dueDate) : null;
  let state: DueState = 'unknown';
  if (milesLeft !== null || daysLeft !== null) {
    if ((milesLeft !== null && milesLeft <= 0) || (daysLeft !== null && daysLeft <= 0)) state = 'overdue';
    else if ((milesLeft !== null && milesLeft <= soonMiles) || (daysLeft !== null && daysLeft <= soonDays)) state = 'soon';
    else state = 'ok';
  }
  return { state, dueMiles, dueDate, milesLeft, daysLeft };
}

const RANK: Record<DueState, number> = { overdue: 0, soon: 1, ok: 2, unknown: 3 };

/** The most urgent reminder (overdue first, then soonest). */
export function nextDue(rs: Reminder[], odometer: number | null, now: string): { reminder: Reminder; status: ReminderStatus } | null {
  const list = rs.map((reminder) => ({ reminder, status: reminderStatus(reminder, odometer, now) })).filter((x) => x.status.state !== 'unknown');
  if (!list.length) return null;
  const score = (s: ReminderStatus) => Math.min(s.milesLeft ?? Infinity, (s.daysLeft ?? Infinity) * 30);
  list.sort((a, b) => RANK[a.status.state] - RANK[b.status.state] || score(a.status) - score(b.status));
  return list[0];
}

export const toNum = (s: string): number | null => { const n = Number(String(s).replace(/,/g, '')); return s.trim() !== '' && Number.isFinite(n) ? n : null; };
