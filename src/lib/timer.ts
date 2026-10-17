import { formatLapTime } from './laptime';

/**
 * Pure stopwatch state. Times are milliseconds from a monotonic clock (performance.now()).
 * `laps` holds completed lap durations; the running lap is `elapsed - lapMark`.
 */
export interface Stopwatch { startedAt: number | null; accumulated: number; lapMark: number; laps: number[] }

export const newWatch = (): Stopwatch => ({ startedAt: null, accumulated: 0, lapMark: 0, laps: [] });
export const running = (w: Stopwatch) => w.startedAt !== null;
export const elapsed = (w: Stopwatch, now: number) => w.accumulated + (w.startedAt !== null ? Math.max(0, now - w.startedAt) : 0);
export const currentLap = (w: Stopwatch, now: number) => elapsed(w, now) - w.lapMark;

export const start = (w: Stopwatch, now: number): Stopwatch => (running(w) ? w : { ...w, startedAt: now });
export const pause = (w: Stopwatch, now: number): Stopwatch => (running(w) ? { ...w, accumulated: elapsed(w, now), startedAt: null } : w);

/** Close the running lap. Ignored when stopped or when the lap would be shorter than `minMs` (debounces double taps). */
export function lap(w: Stopwatch, now: number, minMs = 1000): Stopwatch {
  if (!running(w)) return w;
  const e = elapsed(w, now);
  const d = e - w.lapMark;
  if (d < minMs) return w;
  return { ...w, laps: [...w.laps, d], lapMark: e };
}

/** Best lap in ms, or null. */
export const bestLap = (laps: number[]) => (laps.length ? Math.min(...laps) : null);

/** Laps as Track-log text: one `m:ss.sss` per line (the format `parseLaps` reads). */
export const lapsToText = (laps: number[]) => laps.map((ms) => formatLapTime(ms / 1000, 3)).join('\n');

/** Clock display for elapsed ms: m:ss.cc (or h:mm:ss.cc). */
export function clock(ms: number): string {
  const cs = Math.floor(ms / 10);
  const h = Math.floor(cs / 360000), m = Math.floor((cs % 360000) / 6000), s = Math.floor((cs % 6000) / 100), c = cs % 100;
  const p = (n: number) => String(n).padStart(2, '0');
  return h ? `${h}:${p(m)}:${p(s)}.${p(c)}` : `${m}:${p(s)}.${p(c)}`;
}
