import { load, save } from './storage';
import { carOf, toNum, type CarStore } from './garage';
import type { TrackSession } from './garage';
import type { Timeslip } from './drag';
import type { FillUp } from './fuel';
import type { DynoPull } from './dyno';
import { parseLaps } from './laptime';
import type { MsgKey } from './i18n';

/**
 * Local milestones derived only from what the owner logged (no network, nothing uploaded).
 * Each has progress and, where the data allows, the date it was reached (from the entry that reached it).
 */
export interface AchievementInput { cars: CarStore; track: TrackSession[]; drag: Timeslip[]; fuel: FillUp[]; dyno: DynoPull[]; plans: number }
export interface Achievement { id: string; title: MsgKey; desc: MsgKey; icon: string; current: number; target: number; done: boolean; date: string | null }

const ISO = /^\d{4}-\d{2}-\d{2}$/;
/** Date on which a sorted list of dated items reached `n` items. */
function nthDate(dates: string[], n: number): string | null {
  const s = dates.filter((d) => ISO.test(d)).sort();
  return s.length >= n ? s[n - 1] : null;
}

/** Odometer readings with dates for one car (service/mod entries with miles, fill-ups, reminder last-done). */
export function odometerReadings(car: CarStore['cars'][number], fuel: FillUp[]): { date: string; miles: number }[] {
  const out: { date: string; miles: number }[] = [];
  for (const e of [...car.service, ...car.mods]) { const m = toNum(e.miles ?? ''); if (m !== null && m >= 0) out.push({ date: e.date, miles: m }); }
  for (const f of fuel) if (f.odometer >= 0) out.push({ date: f.date, miles: f.odometer });
  for (const r of car.reminders) if (r.lastMiles !== null && r.lastMiles >= 0 && r.lastDate) out.push({ date: r.lastDate, miles: r.lastMiles });
  return out.sort((a, b) => a.date.localeCompare(b.date) || a.miles - b.miles);
}

/** Miles logged = spread of odometer readings per car, summed over cars. The current odometer counts too. */
export function milesLogged(inp: AchievementInput): { miles: number; reached: (n: number) => string | null } {
  let total = 0;
  const perCar: { date: string; miles: number }[][] = [];
  for (const car of inp.cars.cars) {
    const rs = odometerReadings(car, inp.fuel.filter((f) => carOf(f) === car.id));
    const all = rs.map((r) => r.miles);
    const odo = toNum(car.odometer);
    if (odo !== null && odo >= 0) all.push(odo);
    if (all.length >= 2) total += Math.max(...all) - Math.min(...all);
    perCar.push(rs);
  }
  // Date reached: first dated reading at which the running spread (summed over cars) crossed n.
  const reached = (n: number): string | null => {
    const events = perCar.flatMap((rs, ci) => rs.filter((r) => ISO.test(r.date)).map((r) => ({ ...r, ci }))).sort((a, b) => a.date.localeCompare(b.date));
    const lo: number[] = [], hi: number[] = [];
    for (const e of events) {
      lo[e.ci] = Math.min(lo[e.ci] ?? e.miles, e.miles); hi[e.ci] = Math.max(hi[e.ci] ?? e.miles, e.miles);
      const sum = hi.reduce((s, h, i) => s + (h !== undefined ? h - lo[i] : 0), 0);
      if (sum >= n) return e.date;
    }
    return null;
  };
  return { miles: total, reached };
}

export function computeAchievements(inp: AchievementInput): Achievement[] {
  const cars = inp.cars.cars;
  const service = cars.flatMap((c) => c.service), mods = cars.flatMap((c) => c.mods);
  const strip = inp.drag.filter((d) => !d.gps);
  const laps = inp.track.flatMap((t) => parseLaps(t.laps).laps.map(() => t.date));
  const tenSec = strip.filter((d) => d.quarterEt !== null && d.quarterEt > 0 && d.quarterEt < 11);
  const maintained = cars.flatMap((c) => c.reminders).filter((r) => ISO.test(r.lastDate));
  const ml = milesLogged(inp);
  const mk = (id: string, icon: string, current: number, target: number, date: string | null): Achievement =>
    ({ id, icon, current: Math.min(current, target), target, done: current >= target, date: current >= target ? date : null, title: `ach.${id}.t` as MsgKey, desc: `ach.${id}.d` as MsgKey });
  return [
    mk('firstTrack', '🏁', inp.track.length, 1, nthDate(inp.track.map((t) => t.date), 1)),
    mk('track5', '🏎', inp.track.length, 5, nthDate(inp.track.map((t) => t.date), 5)),
    mk('laps100', '⟳', laps.length, 100, nthDate(laps, 100)),
    mk('firstDrag', '🚦', strip.length, 1, nthDate(strip.map((d) => d.date), 1)),
    mk('drag10', '🔟', strip.length, 10, nthDate(strip.map((d) => d.date), 10)),
    mk('tenSecond', '⏱', tenSec.length, 1, nthDate(tenSec.map((d) => d.date), 1)),
    mk('firstDyno', '📈', inp.dyno.length, 1, nthDate(inp.dyno.map((d) => d.date), 1)),
    mk('firstService', '🔧', service.length, 1, nthDate(service.map((e) => e.date), 1)),
    mk('service10', '🧰', service.length, 10, nthDate(service.map((e) => e.date), 10)),
    mk('maintained', '✔', maintained.length, 1, nthDate(maintained.map((r) => r.lastDate), 1)),
    mk('firstMod', '⚙', mods.length, 1, nthDate(mods.map((e) => e.date), 1)),
    mk('fills10', '⛽', inp.fuel.length, 10, nthDate(inp.fuel.map((f) => f.date), 10)),
    mk('miles1k', '🛣', Math.round(ml.miles), 1000, ml.reached(1000)),
    mk('miles10k', '🌎', Math.round(ml.miles), 10000, ml.reached(10000)),
    mk('plan', '📝', inp.plans, 1, null),
    mk('twoCars', '🚗', cars.length, 2, null),
  ];
}

/** Which unlocked achievements the owner has already seen (so new ones are announced once). */
export const ACH_KEY = 'gt500.achievements.v1';
export interface AchState { seen: string[] }
export function normAch(v: unknown): AchState | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const s = (v as { seen?: unknown }).seen ?? [];
  if (!Array.isArray(s) || s.length > 200 || !s.every((x) => typeof x === 'string' && x.length <= 40)) return null;
  return { seen: [...new Set(s as string[])] };
}
export const loadAch = (): AchState => normAch(load<unknown>(ACH_KEY, null)) ?? { seen: [] };
export const saveAch = (a: AchState) => save(ACH_KEY, a);
/** Newly unlocked ids not yet seen. */
export const unseen = (list: Achievement[], st: AchState) => list.filter((a) => a.done && !st.seen.includes(a.id)).map((a) => a.id);
