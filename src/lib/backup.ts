import { EMPTY_GARAGE, KEYS, loadGarage, loadPlans, loadTrack, type GarageState, type Plan, type TrackSession } from './garage';
import { DRAG_KEY, loadDrag, type Timeslip } from './drag';
import { FUEL_KEY, loadFuel, type FillUp } from './fuel';
import { SETTINGS_KEY, loadSettings, normalizeSettings, type Settings } from './units';
import { QUIZ_KEY } from './quiz';
import { normFill, normGarage, normPlan, normSlip, normTrack } from './validate';
import { remove, save } from './storage';

/**
 * Schema history:
 *  1 — garage, plans, track
 *  2 — adds drag (timeslips), fuel (fill-ups) and settings. v1 files migrate with empty drag/fuel and default settings.
 */
export const SCHEMA_VERSION = 2;
export const APP_ID = 'gt500-companion';
/** Largest backup file accepted for import. */
export const MAX_IMPORT_BYTES = 2 * 1024 * 1024;

export interface Backup {
  app: typeof APP_ID; schema: number; exported: string;
  garage: GarageState; plans: Plan[]; track: TrackSession[]; drag: Timeslip[]; fuel: FillUp[]; settings: Settings;
}

export function makeBackup(garage: GarageState, plans: Plan[], track: TrackSession[], drag: Timeslip[] = [], fuel: FillUp[] = [], settings: Settings = normalizeSettings({}), exported = new Date().toISOString()): Backup {
  return { app: APP_ID, schema: SCHEMA_VERSION, exported, garage, plans, track, drag, fuel, settings };
}

/** Everything currently stored on this device. */
export const currentBackup = () => makeBackup(loadGarage(), loadPlans(), loadTrack(), loadDrag(), loadFuel(), loadSettings());

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);

function strictList<T>(v: unknown, name: string, f: (x: unknown) => T | null, errs: string[]): T[] {
  if (!Array.isArray(v)) { errs.push(`"${name}" must be an array`); return []; }
  const out: T[] = [];
  v.forEach((x, i) => { const n = f(x); if (n === null) errs.push(`${name}[${i}] is malformed`); else out.push(n); });
  return out;
}

/** Bring an older schema up to the current one. */
export function migrate(v: Obj): Obj {
  if (v.schema === 1) return { ...v, schema: 2, drag: v.drag ?? [], fuel: v.fuel ?? [], settings: v.settings ?? {} };
  return v;
}

/** Validate an unknown parsed JSON value. Every field the app renders is type-checked; unknown keys are dropped. */
export function validateBackup(raw: unknown): { ok: true; data: Backup; migratedFrom: number | null } | { ok: false; errors: string[] } {
  const errs: string[] = [];
  if (!isObj(raw)) return { ok: false, errors: ['File is not a JSON object'] };
  if (raw.app !== APP_ID) errs.push(`"app" must be "${APP_ID}"`);
  if (typeof raw.schema !== 'number' || !Number.isInteger(raw.schema) || raw.schema < 1) return { ok: false, errors: [...errs, '"schema" version missing'] };
  if (raw.schema > SCHEMA_VERSION) return { ok: false, errors: [...errs, `Schema ${raw.schema} is newer than this app supports (${SCHEMA_VERSION})`] };
  const from = raw.schema;
  const v = migrate(raw);
  const garage = normGarage(v.garage);
  if (!garage) errs.push('"garage" is malformed (every field must be a string; logs need id, date and title)');
  const plans = strictList(v.plans, 'plans', normPlan, errs);
  const track = strictList(v.track, 'track', normTrack, errs);
  const drag = strictList(v.drag, 'drag', normSlip, errs);
  const fuel = strictList(v.fuel, 'fuel', normFill, errs);
  if (!isObj(v.settings)) errs.push('"settings" must be an object');
  if (errs.length) return { ok: false, errors: errs };
  return {
    ok: true, migratedFrom: from < SCHEMA_VERSION ? from : null,
    data: { app: APP_ID, schema: SCHEMA_VERSION, exported: typeof v.exported === 'string' ? v.exported : '', garage: garage ?? { ...EMPTY_GARAGE }, plans, track, drag, fuel, settings: normalizeSettings(v.settings) },
  };
}

export function parseBackup(text: string) {
  if (text.length > MAX_IMPORT_BYTES) return { ok: false as const, errors: [`File is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB`] };
  try { return validateBackup(JSON.parse(text)); } catch { return { ok: false as const, errors: ['Not valid JSON'] }; }
}

/** Write a validated backup to localStorage. Returns false if any write failed (e.g. quota). */
export function restoreBackup(b: Backup): boolean {
  return [
    save(KEYS.garage, b.garage), save(KEYS.plans, b.plans), save(KEYS.track, b.track),
    save(DRAG_KEY, b.drag), save(FUEL_KEY, b.fuel), save(SETTINGS_KEY, b.settings),
  ].every(Boolean);
}

/** Every key this app writes. */
export const ALL_KEYS = [KEYS.garage, KEYS.plans, KEYS.track, DRAG_KEY, FUEL_KEY, SETTINGS_KEY, QUIZ_KEY, 'gt500.theme'];
export function resetAll(): void { ALL_KEYS.forEach(remove); }
