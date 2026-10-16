import { load, save } from './storage';
import { normGarage, normList, normPlan, normTrack } from './validate';

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
}

export const KEYS = { garage: 'gt500.garage.v1', plans: 'gt500.plans.v1', track: 'gt500.track.v1' } as const;

export const uid = () => Math.random().toString(36).slice(2, 10);
/** Local calendar date (YYYY-MM-DD), not UTC. */
export const today = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

/** Starter reminders. Every interval is a placeholder the owner should edit — none is a Ford figure. */
export const DEFAULT_REMINDERS: Reminder[] = [
  { id: 'r-oil', item: 'Engine oil & filter', everyMiles: 5000, everyMonths: 12, lastMiles: null, lastDate: '' },
  { id: 'r-dct', item: 'DCT fluid (XT-14-L)', everyMiles: 20000, everyMonths: null, lastMiles: null, lastDate: '' },
  { id: 'r-brake', item: 'Brake fluid flush', everyMiles: null, everyMonths: 24, lastMiles: null, lastDate: '' },
  { id: 'r-tires', item: 'Tire inspection / rotation check', everyMiles: 5000, everyMonths: 6, lastMiles: null, lastDate: '' },
];

export const EMPTY_GARAGE: GarageState = { vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: DEFAULT_REMINDERS };

// Loaders validate stored JSON and fall back to defaults, so a corrupt or legacy key cannot crash a page.
export const loadGarage = (): GarageState => normGarage(load<unknown>(KEYS.garage, null)) ?? { ...EMPTY_GARAGE };
export const saveGarage = (g: GarageState) => save(KEYS.garage, g);
export const loadPlans = (): Plan[] => normList(load<unknown>(KEYS.plans, []), normPlan);
export const loadTrack = (): TrackSession[] => normList(load<unknown>(KEYS.track, []), normTrack);

/** Append an entry to the Garage mods log (used by the build planner). */
export function addModsToGarage(titles: { title: string; notes: string }[]): void {
  const g = loadGarage();
  saveGarage({ ...g, mods: [...g.mods, ...titles.map((t) => ({ id: uid(), date: today(), title: t.title, notes: t.notes, miles: '', cost: '' }))] });
}

export type DueState = 'overdue' | 'soon' | 'ok' | 'unknown';
export interface ReminderStatus { state: DueState; dueMiles: number | null; dueDate: string | null; milesLeft: number | null; daysLeft: number | null }

function addMonths(iso: string, months: number): string {
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1 + months, 1));
  const last = new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0)).getUTCDate();
  dt.setUTCDate(Math.min(d, last));
  return dt.toISOString().slice(0, 10);
}

const dayDiff = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 86400000);

/** Due state from the last service and current odometer/date. Whichever limit comes first wins. */
export function reminderStatus(r: Reminder, odometer: number | null, now: string, soonMiles = 500, soonDays = 30): ReminderStatus {
  const dueMiles = r.everyMiles && r.lastMiles !== null ? r.lastMiles + r.everyMiles : null;
  const dueDate = r.everyMonths && /^\d{4}-\d{2}-\d{2}$/.test(r.lastDate) ? addMonths(r.lastDate, r.everyMonths) : null;
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
