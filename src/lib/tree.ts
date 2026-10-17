/**
 * Drag-strip Christmas tree trainer. Pure timing rules so they are unit-tested:
 * - Sportsman (full) tree: the three ambers light one after another 0.5 s apart; green 0.5 s after the last amber.
 * - Pro tree: all three ambers light together; green 0.4 s later.
 * Reaction time = tap time − green time (a "perfect light" is 0.000). Tapping before green is a red light.
 * Car rollout and the stage beams are not modelled, so times are only comparable with each other, not with timeslips.
 */
import { load, save } from './storage';

export type TreeMode = 'sportsman' | 'pro';
export const TREE_KEY = 'gt500.tree.v1';
export const MAX_HISTORY = 100;
/** Random wait (ms) between "staged" and the first amber. */
export const MIN_DELAY_MS = 800, MAX_DELAY_MS = 2500;
/** Taps slower than this count as "no response". */
export const TIMEOUT_MS = 2000;

export interface Schedule { mode: TreeMode; /** Times (ms after staging) each amber row lights. */ ambers: [number, number, number]; green: number }

/** Light times for a run that starts `delay` ms after staging. */
export function schedule(mode: TreeMode, delay: number): Schedule {
  if (mode === 'pro') return { mode, ambers: [delay, delay, delay], green: delay + 400 };
  return { mode, ambers: [delay, delay + 500, delay + 1000], green: delay + 1500 };
}

/** Random delay from `rnd` (0 ≤ rnd < 1). */
export const randomDelay = (rnd: number) => Math.round(MIN_DELAY_MS + rnd * (MAX_DELAY_MS - MIN_DELAY_MS));

/** Which lights are on at time `t` (ms after staging): number of amber rows lit, and green or red. */
export function lightsAt(s: Schedule, t: number, red = false): { ambers: number; green: boolean; red: boolean } {
  if (red) return { ambers: s.ambers.filter((a) => t >= a).length, green: false, red: true };
  if (t >= s.green) return { ambers: 0, green: true, red: false };
  return { ambers: s.ambers.filter((a) => t >= a).length, green: false, red: false };
}

export interface Result { mode: TreeMode; /** seconds; negative = red light. */ rt: number; red: boolean; date: string }

/** Classify a tap at `tap` ms after staging. Null when it came after TIMEOUT_MS past green. */
export function classify(s: Schedule, tap: number, date = new Date().toISOString()): Result | null {
  const rt = (tap - s.green) / 1000;
  if (tap - s.green > TIMEOUT_MS) return null;
  return { mode: s.mode, rt: Math.round(rt * 1000) / 1000, red: rt < 0, date };
}

export interface Stats { runs: number; reds: number; best: number | null; avg: number | null; perfect: number }
/** Stats over good (non-red) runs of one mode. */
export function stats(list: Result[], mode?: TreeMode): Stats {
  const xs = list.filter((r) => !mode || r.mode === mode);
  const good = xs.filter((r) => !r.red).map((r) => r.rt);
  return {
    runs: xs.length, reds: xs.length - good.length,
    best: good.length ? Math.min(...good) : null,
    avg: good.length ? Math.round((good.reduce((a, b) => a + b, 0) / good.length) * 1000) / 1000 : null,
    perfect: good.filter((x) => x === 0).length,
  };
}

export function normResult(v: unknown): Result | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as Record<string, unknown>;
  if ((o.mode !== 'sportsman' && o.mode !== 'pro') || typeof o.rt !== 'number' || !Number.isFinite(o.rt) || Math.abs(o.rt) > 10 || typeof o.date !== 'string') return null;
  return { mode: o.mode, rt: o.rt, red: o.rt < 0, date: o.date.slice(0, 40) };
}
export const loadTree = (): Result[] => { const v = load<unknown>(TREE_KEY, []); return Array.isArray(v) ? v.map(normResult).filter((x): x is Result => !!x).slice(-MAX_HISTORY) : []; };
export const saveTree = (list: Result[]) => save(TREE_KEY, list.slice(-MAX_HISTORY));
