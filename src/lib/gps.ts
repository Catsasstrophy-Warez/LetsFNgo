/**
 * GPS performance meter math. Pure functions over position samples so they can be tested with
 * synthetic traces. Results are APPROXIMATE: phone GPS updates ~1 Hz with metres of error, so
 * crossing times are linearly interpolated between fixes and runs with poor accuracy are refused.
 */

export interface Fix {
  /** ms timestamp (GeolocationPosition.timestamp). */
  t: number; lat: number; lon: number;
  /** Horizontal accuracy radius, metres. */
  accuracy: number;
  /** Doppler speed in m/s from the receiver, if reported. */
  speed: number | null;
}

export type RunKind = '0-60' | '60-130' | 'quarter';
export const RUN_LABEL: Record<RunKind, string> = { '0-60': '0–60 mph', '60-130': '60–130 mph', quarter: '¼ mile' };

export const MPH = 0.44704; // m/s per mph
export const QUARTER_M = 402.336;
/** Worst horizontal accuracy (m) accepted for any fix in a run. */
export const MAX_ACCURACY_M = 10;
/** Largest gap between fixes (ms) accepted inside a run. */
export const MAX_GAP_MS = 2500;
/** Below this speed (mph) the car is treated as stopped (launch detection). */
export const STOP_MPH = 1.5;

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;
/** Great-circle distance in metres. */
export function haversine(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Speed (m/s) at each fix: receiver Doppler speed when present, otherwise distance / time from the previous fix. */
export function speeds(fixes: Fix[]): number[] {
  return fixes.map((f, i) => {
    if (f.speed !== null && Number.isFinite(f.speed) && f.speed >= 0) return f.speed;
    if (i === 0) return 0;
    const dt = (f.t - fixes[i - 1].t) / 1000;
    return dt > 0 ? haversine(fixes[i - 1], f) / dt : 0;
  });
}

/** Cumulative distance (m) along the trace. */
export function cumulative(fixes: Fix[]): number[] {
  const out = [0];
  for (let i = 1; i < fixes.length; i++) out.push(out[i - 1] + haversine(fixes[i - 1], fixes[i]));
  return out;
}

/** Time (ms) at which series `v` first reaches `target` at or after index `from`, linearly interpolated. */
function crossing(ts: number[], v: number[], target: number, from = 0): { t: number; i: number } | null {
  for (let i = Math.max(1, from); i < v.length; i++) {
    if (v[i] >= target && v[i - 1] < target) {
      const k = (target - v[i - 1]) / (v[i] - v[i - 1]);
      return { t: ts[i - 1] + k * (ts[i] - ts[i - 1]), i };
    }
  }
  return null;
}

export type GpsResult =
  | { ok: true; kind: RunKind; seconds: number; trapMph: number | null; worstAccuracyM: number; fixes: number }
  | { ok: false; reason: string; /** True when the target was reached but the run is refused (accuracy / gaps): stop and report. */ final?: boolean };

/**
 * Time one run from a trace. The trace should start before the run (stopped for 0–60 and ¼ mile,
 * below 60 mph for 60–130). Refuses when any fix in the timed window is worse than `maxAcc` metres,
 * when fixes are too sparse, or when the target is not reached.
 */
export function analyzeRun(kind: RunKind, fixes: Fix[], maxAcc = MAX_ACCURACY_M): GpsResult {
  if (fixes.length < 3) return { ok: false, reason: 'Not enough GPS fixes.' };
  const ts = fixes.map((f) => f.t);
  const v = speeds(fixes);
  let startT: number, startI: number, endT: number, endI: number, trap: number | null = null;
  if (kind === 'quarter' || kind === '0-60') {
    // Launch = last stopped fix before the speed rises through STOP_MPH.
    const launch = crossing(ts, v, STOP_MPH * MPH);
    if (!launch) return { ok: false, reason: 'No launch from a stop was detected.' };
    startI = launch.i - 1;
    // Back-extrapolate from the STOP_MPH crossing to zero speed using the local acceleration.
    const dt = (ts[launch.i] - ts[startI]) / 1000;
    const acc = dt > 0 ? (v[launch.i] - v[startI]) / dt : 0;
    startT = Math.max(ts[startI], acc > 0 ? launch.t - ((STOP_MPH * MPH) / acc) * 1000 : ts[startI]);
    if (kind === '0-60') {
      const end = crossing(ts, v, 60 * MPH, launch.i);
      if (!end) return { ok: false, reason: '60 mph was not reached.' };
      endT = end.t; endI = end.i;
    } else {
      const cum = cumulative(fixes);
      const d = cum.map((x, i) => (i < startI ? 0 : x - cum[startI]));
      const end = crossing(ts, d, QUARTER_M, launch.i);
      if (!end) return { ok: false, reason: 'A full ¼ mile was not covered.' };
      endT = end.t; endI = end.i;
      const k = (endT - ts[end.i - 1]) / (ts[end.i] - ts[end.i - 1] || 1);
      trap = (v[end.i - 1] + k * (v[end.i] - v[end.i - 1])) / MPH;
    }
  } else {
    const a = crossing(ts, v, 60 * MPH);
    if (!a) return { ok: false, reason: 'Speed never rose through 60 mph.' };
    const b = crossing(ts, v, 130 * MPH, a.i);
    if (!b) return { ok: false, reason: '130 mph was not reached.' };
    startT = a.t; startI = a.i - 1; endT = b.t; endI = b.i;
  }
  const window = fixes.slice(startI, endI + 1);
  const worst = Math.max(...window.map((f) => f.accuracy));
  if (!(worst <= maxAcc)) return { ok: false, final: true, reason: `GPS accuracy too poor (worst ±${Math.round(worst)} m; need ±${maxAcc} m or better).` };
  for (let i = startI + 1; i <= endI; i++) if (ts[i] - ts[i - 1] > MAX_GAP_MS) return { ok: false, final: true, reason: 'GPS fixes were too far apart.' };
  return { ok: true, kind, seconds: (endT - startT) / 1000, trapMph: trap, worstAccuracyM: worst, fixes: window.length };
}

/** Readiness from the latest fix: ready only when accuracy is within the limit. */
export function accuracyState(acc: number | null, maxAcc = MAX_ACCURACY_M): 'none' | 'poor' | 'ok' {
  if (acc === null || !Number.isFinite(acc)) return 'none';
  return acc <= maxAcc ? 'ok' : 'poor';
}

/** Build a synthetic constant-acceleration trace heading north (for tests and demos). */
export function syntheticTrace(opts: { accelMps2: number; seconds: number; hz?: number; accuracy?: number; v0?: number; idle?: number; useSpeed?: boolean; lat0?: number; lon0?: number }): Fix[] {
  const { accelMps2, seconds, hz = 5, accuracy = 3, v0 = 0, idle = 1, useSpeed = true, lat0 = 33.0, lon0 = -97.0 } = opts;
  const out: Fix[] = [];
  const mPerDegLat = (Math.PI / 180) * R;
  const n = Math.round((idle + seconds) * hz);
  for (let i = 0; i <= n; i++) {
    const tt = i / hz;
    const run = Math.max(0, tt - idle);
    const d = v0 * tt + 0.5 * accelMps2 * run * run;
    const sp = v0 + accelMps2 * run;
    out.push({ t: 1_000_000 + tt * 1000, lat: lat0 + d / mPerDegLat, lon: lon0, accuracy, speed: useSpeed ? sp : null });
  }
  return out;
}
