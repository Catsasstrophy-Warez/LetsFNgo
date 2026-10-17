import { DEFAULT_CAR_ID, EMPTY_GARAGE, carOf, KEYS, loadCars, loadPlans, loadTrack, type CarStore, type GarageState, type Plan, type TrackSession } from './garage';
import { ACH_KEY, loadAch, normAch, type AchState } from './achievements';
import { DRAG_KEY, loadDrag, type Timeslip } from './drag';
import { FUEL_KEY, loadFuel, type FillUp } from './fuel';
import { SETTINGS_KEY, loadSettings, normalizeSettings, type Settings } from './units';
import { QUIZ_KEY } from './quiz';
import { DEFAULT_ONBOARDING, normCarStore, normFill, normGarage, normOnboarding, normPlan, normSlip, normTrack, type Onboarding } from './validate';
import { ONBOARDING_KEY, loadOnboarding } from './onboarding';
import { remove, save } from './storage';
import { INSTALL_KEY } from './install';
import { WEATHER_KEY } from './weather';
import { DYNO_KEY, loadDyno, type DynoPull } from './dyno';
import { NOTIFY_KEY, loadNotify } from './notify';
import { DASH_KEY, DEFAULT_DASH, loadDash, normDashboard } from './dashboard';
import { DEFAULT_NOTIFY, normDyno, normNotify, normPhotoBackup, type DashLayout, type NotifyPrefs } from './validate';
import { PTC_KEY, loadPtc, normPtc, type PtcTemplate } from './ptc';
import { MAX_PER_OWNER, MAX_PHOTOS, MAX_TOTAL_BYTES, type PhotoBackup } from './photoLimits';
import { MAX_EVENTS, TRACKDAYS_KEY, loadTrackDays, normTrackDay, type TrackDay } from './trackdays';
import { TREE_KEY } from './tree';
import { DIAG_KEY } from './diag';
import { BUYER_KEY, loadBuyer, normBuyer, type BuyerState } from './buyer';
import { COST_KEY, loadCost, normCost, type CostStore } from './costStore';

/**
 * Schema history:
 *  1 — garage, plans, track
 *  2 — adds drag (timeslips), fuel (fill-ups) and settings. v1 files migrate with empty drag/fuel and default settings.
 *  3 — adds onboarding (first-run intro state) and the optional `gps` field on timeslips (GPS-meter estimates).
 *      v2 files migrate with onboarding marked done (an existing user never sees the intro again).
 *  4 — adds dyno pulls, notification preference (permission itself is never restored) and Home layout.
 *      v3 files migrate with no pulls, notifications off and the default Home layout.
 *  5 — multi-car Garage: `garage` becomes `cars` ({ active, cars: [{ id, ...garage }] }); track, drag, fuel and dyno
 *      entries may carry `carId`. v4 files migrate losslessly to one car with id "car1" (entries without carId belong to it).
 *  6 — adds `achievements` ({ seen: [...] }, which unlocked milestones were already announced). v5 files migrate with none seen.
 *  7 — track sessions may carry `gps` (GPS lap timer: timing lines, laps with accuracy, and a capped trace of at most
 *      MAX_TRACE_POINTS samples). v6 files migrate unchanged (no session has GPS data). The import size cap grows to 4 MB.
 *  8 — adds `ptc` (owner's pre-track checklist items), track sessions may carry `checklist` (that event's ticked copy),
 *      and an optional `photos` list (only when exported with "Include photos": base64 JPEGs, validated and capped at
 *      MAX_IMPORT_BYTES_PHOTOS). v7 files migrate with no checklist items; a file without `photos` keeps this
 *      device's photos on import, one with `photos` replaces them.
 *  9 — adds `trackdays` (track day planner events with packing lists). v8 files migrate with no events.
 * 10 — adds `buyer` (Buyer's guide checklist ticks: { checked: [item ids] }). v9 files migrate with nothing ticked.
 * 11 — adds `cost` (Cost of ownership inputs per car: { cars: { [carId]: inputs } }). v10 files migrate with no inputs.
 */
export const SCHEMA_VERSION = 11;
export const APP_ID = 'gt500-companion';
/** Largest backup file accepted for import. */
export const MAX_IMPORT_BYTES = 4 * 1024 * 1024;
/** Largest backup accepted when it includes photos (base64 makes photos about 4/3 their stored size). */
export const MAX_IMPORT_BYTES_PHOTOS = 64 * 1024 * 1024;

export interface Backup {
  app: typeof APP_ID; schema: number; exported: string;
  cars: CarStore; plans: Plan[]; track: TrackSession[]; drag: Timeslip[]; fuel: FillUp[]; settings: Settings; onboarding: Onboarding;
  dyno: DynoPull[]; notify: NotifyPrefs; dashboard: DashLayout; achievements: AchState; ptc: PtcTemplate; trackdays: TrackDay[]; buyer: BuyerState; cost: CostStore;
  /** Present only in an export made with "Include photos". */
  photos?: PhotoBackup[];
}

/** Wrap a single Garage as a one-car store (accepts a store unchanged). */
export const asStore = (g: GarageState | CarStore): CarStore => ('cars' in g && Array.isArray(g.cars) ? g : { active: DEFAULT_CAR_ID, cars: [{ ...(g as GarageState), id: DEFAULT_CAR_ID }] });

export function makeBackup(garage: GarageState | CarStore, plans: Plan[], track: TrackSession[], drag: Timeslip[] = [], fuel: FillUp[] = [], settings: Settings = normalizeSettings({}), exported = new Date().toISOString(), onboarding: Onboarding = { ...DEFAULT_ONBOARDING },
  extra: { dyno?: DynoPull[]; notify?: NotifyPrefs; dashboard?: DashLayout; achievements?: AchState; ptc?: PtcTemplate; trackdays?: TrackDay[]; buyer?: BuyerState; cost?: CostStore; photos?: PhotoBackup[] } = {}): Backup {
  return { app: APP_ID, schema: SCHEMA_VERSION, exported, cars: asStore(garage), plans, track, drag, fuel, settings, onboarding,
    dyno: extra.dyno ?? [], notify: extra.notify ?? { ...DEFAULT_NOTIFY, sent: {} }, dashboard: extra.dashboard ?? { ...DEFAULT_DASH, order: [...DEFAULT_DASH.order] }, achievements: extra.achievements ?? { seen: [] },
    ptc: extra.ptc ?? { items: [] }, trackdays: extra.trackdays ?? [], buyer: extra.buyer ?? { checked: [] }, cost: extra.cost ?? { cars: {} }, ...(extra.photos ? { photos: extra.photos } : {}) };
}

/** Everything currently stored on this device. */
export const currentBackup = () => makeBackup(loadCars(), loadPlans(), loadTrack(), loadDrag(), loadFuel(), loadSettings(), undefined, loadOnboarding(), { dyno: loadDyno(), notify: loadNotify(), dashboard: loadDash(), achievements: loadAch(), ptc: loadPtc(), trackdays: loadTrackDays(), buyer: loadBuyer(), cost: loadCost() });

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
  let o = v;
  if (o.schema === 1) o = { ...o, schema: 2, drag: o.drag ?? [], fuel: o.fuel ?? [], settings: o.settings ?? {} };
  if (o.schema === 2) o = { ...o, schema: 3, onboarding: o.onboarding ?? { done: true, completed: '' } };
  if (o.schema === 3) o = { ...o, schema: 4, dyno: o.dyno ?? [], notify: o.notify ?? { enabled: false, sent: {} }, dashboard: o.dashboard ?? { order: [...DEFAULT_DASH.order], hidden: [] } };
  if (o.schema === 4) {
    const { garage, ...rest } = o;
    // Keep a malformed garage as-is so validation reports it instead of silently replacing it.
    o = { ...rest, schema: 5, cars: isObj(garage) ? { active: DEFAULT_CAR_ID, cars: [{ ...garage, id: DEFAULT_CAR_ID }] } : garage === undefined ? { active: DEFAULT_CAR_ID, cars: [{ id: DEFAULT_CAR_ID }] } : garage };
  }
  if (o.schema === 5) o = { ...o, schema: 6, achievements: o.achievements ?? { seen: [] } };
  if (o.schema === 6) o = { ...o, schema: 7 };
  if (o.schema === 7) o = { ...o, schema: 8, ptc: o.ptc ?? { items: [] } };
  if (o.schema === 8) o = { ...o, schema: 9, trackdays: o.trackdays ?? [] };
  if (o.schema === 9) o = { ...o, schema: 10, buyer: o.buyer ?? { checked: [] } };
  if (o.schema === 10) o = { ...o, schema: 11, cost: o.cost ?? { cars: {} } };
  return o;
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
  const cars = normCarStore(v.cars);
  if (!cars) errs.push(isObj(v.cars) && Array.isArray(v.cars.cars) && v.cars.cars.length === 1 && !normGarage(v.cars.cars[0])
    ? '"garage" is malformed (every field must be a string; logs need id, date and title)'
    : '"cars" is malformed (1–12 cars with unique ids; every field must be a string; logs need id, date and title)');
  const achievements = normAch(v.achievements);
  if (!achievements) errs.push('"achievements" is malformed');
  const plans = strictList(v.plans, 'plans', normPlan, errs);
  const track = strictList(v.track, 'track', normTrack, errs);
  const drag = strictList(v.drag, 'drag', normSlip, errs);
  const fuel = strictList(v.fuel, 'fuel', normFill, errs);
  if (!isObj(v.settings)) errs.push('"settings" must be an object');
  const onboarding = normOnboarding(v.onboarding);
  if (!onboarding) errs.push('"onboarding" is malformed');
  const dyno = strictList(v.dyno, 'dyno', normDyno, errs);
  const notify = normNotify(v.notify);
  if (!notify) errs.push('"notify" is malformed');
  const dashboard = normDashboard(v.dashboard);
  if (!dashboard) errs.push('"dashboard" is malformed');
  const ptc = normPtc(v.ptc);
  if (!ptc) errs.push('"ptc" is malformed');
  const trackdays = strictList(v.trackdays, 'trackdays', normTrackDay, errs);
  if (trackdays.length > MAX_EVENTS) errs.push(`"trackdays" has more than ${MAX_EVENTS} events`);
  // Two events with one id would be edited and deleted together in the planner.
  if (new Set(trackdays.map((d) => d.id)).size !== trackdays.length) errs.push('"trackdays" repeats an event id');
  const buyer = normBuyer(v.buyer);
  if (!buyer) errs.push('"buyer" is malformed');
  const cost = normCost(v.cost);
  if (!cost) errs.push('"cost" is malformed');
  let photos: PhotoBackup[] | undefined;
  if (v.photos !== undefined) {
    photos = strictList(v.photos, 'photos', normPhotoBackup, errs);
    if (photos.length > MAX_PHOTOS) errs.push(`"photos" has more than ${MAX_PHOTOS} photos`);
    if (new Set(photos.map((p) => p.id)).size !== photos.length) errs.push('"photos" repeats a photo id');
    const per = new Map<string, number>();
    for (const p of photos) per.set(`${p.kind}:${p.ownerId}`, (per.get(`${p.kind}:${p.ownerId}`) ?? 0) + 1);
    if ([...per.values()].some((n) => n > MAX_PER_OWNER)) errs.push(`"photos" has more than ${MAX_PER_OWNER} photos on one entry`);
    if (photos.reduce((a, p) => a + (p.data.length / 4) * 3, 0) > MAX_TOTAL_BYTES) errs.push('"photos" are larger than the photo storage limit');
  }
  if (errs.length) return { ok: false, errors: errs };
  // Entries that point at a car the file does not contain are re-homed to the first car instead of becoming invisible.
  const ids = new Set((cars?.cars ?? []).map((c) => c.id));
  const first = cars?.cars[0]?.id ?? DEFAULT_CAR_ID;
  const home = <T extends { carId?: string }>(xs: T[]): T[] => xs.map((e) => (ids.has(carOf(e)) ? e : { ...e, carId: first }));
  return {
    ok: true, migratedFrom: from < SCHEMA_VERSION ? from : null,
    data: { app: APP_ID, schema: SCHEMA_VERSION, exported: typeof v.exported === 'string' ? v.exported : '', cars: cars ?? { active: DEFAULT_CAR_ID, cars: [{ ...EMPTY_GARAGE, id: DEFAULT_CAR_ID }] }, plans, track: home(track), drag: home(drag), fuel: home(fuel), settings: normalizeSettings(v.settings), onboarding: onboarding ?? { ...DEFAULT_ONBOARDING },
      dyno: home(dyno), notify: notify ?? { ...DEFAULT_NOTIFY, sent: {} }, dashboard: dashboard ?? { ...DEFAULT_DASH }, achievements: achievements ?? { seen: [] },
      ptc: ptc ?? { items: [] }, trackdays, buyer: buyer ?? { checked: [] }, cost: cost ?? { cars: {} }, ...(photos ? { photos } : {}) },
  };
}

/** Parse and validate a backup file. Files over MAX_IMPORT_BYTES are accepted only when they carry photos (up to MAX_IMPORT_BYTES_PHOTOS). */
export function parseBackup(text: string) {
  if (text.length > MAX_IMPORT_BYTES_PHOTOS) return { ok: false as const, errors: [`File is larger than ${MAX_IMPORT_BYTES_PHOTOS / 1024 / 1024} MB`] };
  // Over the plain cap only a file with photos is worth parsing.
  if (text.length > MAX_IMPORT_BYTES && !/"photos"\s*:\s*\[\s*\{/.test(text)) return { ok: false as const, errors: [`File is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB`] };
  let raw: unknown;
  try { raw = JSON.parse(text); } catch { return { ok: false as const, errors: ['Not valid JSON'] }; }
  if (text.length > MAX_IMPORT_BYTES && !(isObj(raw) && Array.isArray(raw.photos) && raw.photos.length)) return { ok: false as const, errors: [`File is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB`] };
  return validateBackup(raw);
}

/** The export file text. With photos it can be large; it is refused (null) if it would exceed what import accepts. */
export async function buildExport(includePhotos: boolean, getPhotos: () => Promise<PhotoBackup[]>): Promise<{ ok: true; text: string; photos: number } | { ok: false; error: 'tooBig' | 'photos' }> {
  const b = currentBackup();
  let photos: PhotoBackup[] | undefined;
  if (includePhotos) { try { photos = await getPhotos(); } catch { return { ok: false, error: 'photos' }; } }
  const text = JSON.stringify(photos ? { ...b, photos } : b, null, photos ? 0 : 2);
  if (text.length > (photos?.length ? MAX_IMPORT_BYTES_PHOTOS : MAX_IMPORT_BYTES)) return { ok: false, error: 'tooBig' };
  return { ok: true, text, photos: photos?.length ?? 0 };
}

/** Write a validated backup to localStorage. Returns false if any write failed (e.g. quota). */
export function restoreBackup(b: Backup): boolean {
  // The restored cars replace the legacy single-car key too, so a stale copy can never resurface as a fallback.
  remove(KEYS.garage);
  return [
    save(KEYS.cars, b.cars), save(KEYS.plans, b.plans), save(KEYS.track, b.track),
    save(DRAG_KEY, b.drag), save(FUEL_KEY, b.fuel), save(SETTINGS_KEY, b.settings), save(ONBOARDING_KEY, b.onboarding),
    save(DYNO_KEY, b.dyno), save(NOTIFY_KEY, b.notify), save(DASH_KEY, b.dashboard), save(ACH_KEY, b.achievements), save(PTC_KEY, b.ptc), save(TRACKDAYS_KEY, b.trackdays), save(BUYER_KEY, b.buyer), save(COST_KEY, b.cost),
  ].every(Boolean);
}

/** Every key this app writes. */
export const ALL_KEYS = [WEATHER_KEY, 'gt500.recentSearches.v1' /* search.ts RECENT_KEY; not imported to keep the data index out of this chunk */, KEYS.garage, KEYS.cars, KEYS.plans, KEYS.track, DRAG_KEY, FUEL_KEY, SETTINGS_KEY, QUIZ_KEY, ONBOARDING_KEY, DYNO_KEY, NOTIFY_KEY, DASH_KEY, ACH_KEY, INSTALL_KEY, PTC_KEY, TRACKDAYS_KEY, BUYER_KEY, COST_KEY, 'gt500.buildSheet.v1' /* buildSheet.ts BUILD_KEY; reset only, not in backups; kept out of this chunk */, TREE_KEY, 'gt500.sflDir.v1' /* lapTimer.ts SFL_DIR_KEY; kept out of this chunk */, DIAG_KEY, 'gt500.theme'];
export function resetAll(): void { ALL_KEYS.forEach(remove); }
