import { EMPTY_GARAGE, type GarageState, type Plan, type TrackSession } from './garage';

export const SCHEMA_VERSION = 1;
export const APP_ID = 'gt500-companion';

export interface Backup { app: typeof APP_ID; schema: number; exported: string; garage: GarageState; plans: Plan[]; track: TrackSession[] }

export function makeBackup(garage: GarageState, plans: Plan[], track: TrackSession[], exported = new Date().toISOString()): Backup {
  return { app: APP_ID, schema: SCHEMA_VERSION, exported, garage, plans, track };
}

const SESSION_DEFAULTS = { conditions: '', airTemp: '', notes: '', pressures: { fl: '', fr: '', rl: '', rr: '' } };

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const isStr = (v: unknown) => typeof v === 'string';
const numOrNull = (v: unknown) => v === null || (typeof v === 'number' && Number.isFinite(v));

function checkLog(v: unknown, path: string, errs: string[]) {
  if (!Array.isArray(v)) { errs.push(`${path} must be an array`); return; }
  v.forEach((e, i) => { if (!isObj(e) || !isStr(e.id) || !isStr(e.date) || !isStr(e.title)) errs.push(`${path}[${i}] needs id, date and title strings`); });
}

/** Validate an unknown parsed JSON value. Returns the normalized backup or a list of problems. */
export function validateBackup(v: unknown): { ok: true; data: Backup } | { ok: false; errors: string[] } {
  const errs: string[] = [];
  if (!isObj(v)) return { ok: false, errors: ['File is not a JSON object'] };
  if (v.app !== APP_ID) errs.push(`"app" must be "${APP_ID}"`);
  if (typeof v.schema !== 'number') errs.push('"schema" version missing');
  else if (v.schema > SCHEMA_VERSION) errs.push(`Schema ${v.schema} is newer than this app supports (${SCHEMA_VERSION})`);
  const g = v.garage;
  if (!isObj(g)) errs.push('"garage" must be an object');
  else {
    for (const k of ['vin', 'year', 'color', 'nickname'] as const) if (g[k] !== undefined && !isStr(g[k])) errs.push(`garage.${k} must be a string`);
    if (g.odometer !== undefined && !isStr(g.odometer)) errs.push('garage.odometer must be a string');
    checkLog(g.mods ?? [], 'garage.mods', errs);
    checkLog(g.service ?? [], 'garage.service', errs);
    if (g.reminders !== undefined) {
      if (!Array.isArray(g.reminders)) errs.push('garage.reminders must be an array');
      else g.reminders.forEach((r, i) => {
        if (!isObj(r) || !isStr(r.id) || !isStr(r.item) || !numOrNull(r.everyMiles) || !numOrNull(r.everyMonths) || !numOrNull(r.lastMiles) || !isStr(r.lastDate))
          errs.push(`garage.reminders[${i}] is malformed`);
      });
    }
  }
  if (!Array.isArray(v.plans)) errs.push('"plans" must be an array');
  else v.plans.forEach((p, i) => { if (!isObj(p) || !isStr(p.id) || !isStr(p.name) || !Array.isArray(p.modIds) || !p.modIds.every(isStr)) errs.push(`plans[${i}] is malformed`); });
  if (!Array.isArray(v.track)) errs.push('"track" must be an array');
  else v.track.forEach((t, i) => { if (!isObj(t) || !isStr(t.id) || !isStr(t.date) || !isStr(t.track) || !isStr(t.laps) || !isObj(t.pressures)) errs.push(`track[${i}] is malformed`); });
  if (errs.length) return { ok: false, errors: errs };
  const o = v as unknown as Backup;
  return {
    ok: true,
    data: {
      app: APP_ID, schema: SCHEMA_VERSION, exported: isStr(v.exported) ? String(v.exported) : '',
      garage: { ...EMPTY_GARAGE, ...o.garage },
      plans: o.plans.map((p) => ({ ...p, created: p.created ?? '' })),
      track: o.track.map((t) => ({ ...SESSION_DEFAULTS, ...t, pressures: { ...SESSION_DEFAULTS.pressures, ...t.pressures } })),
    },
  };
}

export function parseBackup(text: string) {
  try { return validateBackup(JSON.parse(text)); } catch { return { ok: false as const, errors: ['Not valid JSON'] }; }
}
