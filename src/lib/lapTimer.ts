/**
 * GPS lap timer math. Pure functions over position fixes so every rule can be tested with synthetic circuits.
 *
 * Positions are projected to a local flat x/y plane in metres (equirectangular around a reference point, accurate
 * to well under a centimetre over a circuit-sized area). A start/finish line is a segment; a lap starts or ends when
 * the segment between two consecutive (smoothed) fixes intersects it in the allowed direction. The crossing time is
 * interpolated between the two fixes by where along the segment the intersection falls, so a 1 Hz receiver still
 * gives sub-fix timing. Results are APPROXIMATE: phone GPS has metres of error, so laps whose fixes are too inaccurate
 * or too far apart are refused instead of being shown with false precision.
 */
import { haversine, type Fix } from './gps';

export interface LatLon { lat: number; lon: number }
/** A timing line between two points. `dir` (+1 / −1) is the side-to-side crossing direction that counts; 0 = both. */
export interface TimingLine { a: LatLon; b: LatLon; dir: 1 | -1 | 0 }
export interface XY { x: number; y: number }

/** Worst horizontal accuracy (m) accepted for the fixes either side of a crossing and inside a lap. */
export const LAP_MAX_ACCURACY_M = 15;
/** Largest gap between fixes (ms) accepted inside a lap. */
export const LAP_MAX_GAP_MS = 3000;
/** Crossings closer together than this (ms) are treated as jitter around the line, not a new lap. */
export const MIN_LAP_MS = 20_000;
/** Width (m) of a line dropped at the current position, perpendicular to the direction of travel. */
export const DROP_LINE_WIDTH_M = 30;

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;

/** Local projection around `ref`: metres east (x) and north (y). */
export function projector(ref: LatLon) {
  const k = Math.cos(rad(ref.lat));
  return {
    toXY: (p: LatLon): XY => ({ x: rad(p.lon - ref.lon) * R * k, y: rad(p.lat - ref.lat) * R }),
    toLatLon: (q: XY): LatLon => ({ lat: ref.lat + (q.y / R) * (180 / Math.PI), lon: ref.lon + (q.x / (R * k)) * (180 / Math.PI) }),
  };
}

const cross = (a: XY, b: XY) => a.x * b.y - a.y * b.x;
const sub = (a: XY, b: XY): XY => ({ x: a.x - b.x, y: a.y - b.y });

/**
 * Intersection of segment p1→p2 with segment q1→q2. Returns `u` (0..1, position along p) and the crossing side
 * (+1 when p moves from the right of q1→q2 to the left, −1 the other way), or null when they do not cross.
 * Collinear / parallel segments never count.
 */
export function segmentIntersect(p1: XY, p2: XY, q1: XY, q2: XY): { u: number; side: 1 | -1 } | null {
  const r = sub(p2, p1), s = sub(q2, q1);
  const den = cross(r, s);
  if (Math.abs(den) < 1e-12) return null;
  const qp = sub(q1, p1);
  const u = cross(qp, s) / den;
  const v = cross(qp, r) / den;
  if (u < 0 || u > 1 || v < 0 || v > 1) return null;
  // Side of p1 relative to q1→q2: negative cross = right. Moving right → left is +1.
  return { u, side: cross(s, sub(p1, q1)) < 0 ? 1 : -1 };
}

/** Light positional smoothing: centred 3-fix average of lat/lon (ends kept), weighted by inverse accuracy. Time is unchanged. */
export function smoothFixes(fixes: Fix[]): Fix[] {
  if (fixes.length < 3) return fixes.slice();
  return fixes.map((f, i) => {
    if (i === 0 || i === fixes.length - 1) return f;
    const w = [fixes[i - 1], f, fixes[i + 1]];
    const ws = w.map((x) => 1 / Math.max(1, x.accuracy));
    // Centre fix counts double so a single outlier neighbour cannot drag the trace far.
    ws[1] *= 2;
    const tot = ws.reduce((a, b) => a + b, 0);
    return { ...f, lat: w.reduce((a, x, k) => a + x.lat * ws[k], 0) / tot, lon: w.reduce((a, x, k) => a + x.lon * ws[k], 0) / tot };
  });
}

/** Line through `at`, perpendicular to the direction from `prev` to `at`, `width` metres wide, counting only that direction. */
export function lineFromHeading(prev: LatLon, at: LatLon, width = DROP_LINE_WIDTH_M): TimingLine | null {
  const pr = projector(at);
  const h = sub(pr.toXY(at), pr.toXY(prev));
  const len = Math.hypot(h.x, h.y);
  if (!(len > 0.5)) return null; // not moving: no heading
  const n = { x: -h.y / len, y: h.x / len }; // left normal
  const a = pr.toLatLon({ x: (n.x * width) / 2, y: (n.y * width) / 2 });
  const b = pr.toLatLon({ x: (-n.x * width) / 2, y: (-n.y * width) / 2 });
  // Travelling along h crosses a(left)→b(right)... determine the counted side with a probe segment.
  const P = projector(a);
  const hit = segmentIntersect(P.toXY(prev), P.toXY({ lat: at.lat + (at.lat - prev.lat), lon: at.lon + (at.lon - prev.lon) }), P.toXY(a), P.toXY(b));
  return { a, b, dir: hit ? hit.side : 1 };
}

/** Line from two typed / tapped points. `dir` 0 counts both directions (the first crossing then sets it, see `detectCrossings`). */
export const lineFromPoints = (a: LatLon, b: LatLon, dir: 1 | -1 | 0 = 0): TimingLine => ({ a, b, dir });

export const lineLength = (l: TimingLine) => haversine(l.a, l.b);

export interface Crossing { /** Interpolated crossing time (ms). */ t: number; /** Index of the fix after the crossing. */ i: number; side: 1 | -1; /** Worst accuracy of the two fixes. */ acc: number; /** Gap between the two fixes (ms). */ gapMs: number }

/**
 * Every crossing of `line` by the (already cleaned) trace, in time order. Crossings in the wrong direction are
 * dropped; with `dir` 0 the first crossing fixes the direction. Crossings within `minMs` of the last kept one are
 * jitter and dropped. Smoothing is applied first.
 */
export function detectCrossings(rawFixes: Fix[], line: TimingLine, opts: { minMs?: number; smooth?: boolean } = {}): Crossing[] {
  const { minMs = MIN_LAP_MS, smooth = true } = opts;
  const fixes = smooth ? smoothFixes(rawFixes) : rawFixes;
  if (fixes.length < 2) return [];
  const P = projector(line.a);
  const q1 = P.toXY(line.a), q2 = P.toXY(line.b);
  const pts = fixes.map((f) => P.toXY(f));
  let dir = line.dir;
  const out: Crossing[] = [];
  for (let i = 1; i < fixes.length; i++) {
    const hit = segmentIntersect(pts[i - 1], pts[i], q1, q2);
    if (!hit) continue;
    if (dir === 0) dir = hit.side;
    if (hit.side !== dir) continue;
    const t = fixes[i - 1].t + hit.u * (fixes[i].t - fixes[i - 1].t);
    if (out.length && t - out[out.length - 1].t < minMs) continue;
    out.push({ t, i, side: hit.side, acc: Math.max(fixes[i - 1].accuracy, fixes[i].accuracy), gapMs: fixes[i].t - fixes[i - 1].t });
  }
  return out;
}

export interface Lap {
  n: number; startT: number; endT: number; seconds: number;
  /** Sector times (s) when sector lines are set and each was crossed once inside the lap, else null. */
  sectors: number[] | null;
  worstAccuracyM: number; maxGapMs: number;
  /** Index range of fixes inside the lap (inclusive), into the cleaned fix list. */
  from: number; to: number;
  valid: boolean; reason: 'accuracy' | 'gap' | null;
}

export interface LapOpts { maxAcc?: number; maxGapMs?: number; minMs?: number; sectors?: TimingLine[] }

/**
 * Laps between consecutive start/finish crossings. A lap is refused (valid: false) when any fix in it, or either fix
 * of its bounding crossings, is worse than `maxAcc`, or when two fixes are more than `maxGapMs` apart.
 */
export function buildLaps(fixes: Fix[], line: TimingLine, opts: LapOpts = {}): Lap[] {
  const { maxAcc = LAP_MAX_ACCURACY_M, maxGapMs = LAP_MAX_GAP_MS, minMs = MIN_LAP_MS, sectors = [] } = opts;
  const xs = detectCrossings(fixes, line, { minMs });
  const secX = sectors.map((s) => detectCrossings(fixes, s, { minMs: minMs / 4 }));
  const laps: Lap[] = [];
  for (let k = 1; k < xs.length; k++) {
    const a = xs[k - 1], b = xs[k];
    const from = a.i - 1, to = b.i;
    let worst = Math.max(a.acc, b.acc), gap = Math.max(a.gapMs, b.gapMs);
    for (let i = from; i <= to; i++) {
      worst = Math.max(worst, fixes[i].accuracy);
      if (i > from) gap = Math.max(gap, fixes[i].t - fixes[i - 1].t);
    }
    let sec: number[] | null = null;
    if (sectors.length) {
      const marks = secX.map((list) => list.filter((c) => c.t > a.t && c.t < b.t));
      if (marks.every((m) => m.length === 1)) {
        const ts = [a.t, ...marks.map((m) => m[0].t).sort((x, y) => x - y), b.t];
        sec = ts.slice(1).map((t, j) => (t - ts[j]) / 1000);
      }
    }
    const reason = worst > maxAcc ? 'accuracy' : gap > maxGapMs ? 'gap' : null;
    laps.push({ n: k, startT: a.t, endT: b.t, seconds: (b.t - a.t) / 1000, sectors: sec, worstAccuracyM: worst, maxGapMs: gap, from, to, valid: reason === null, reason });
  }
  return laps;
}

export const bestLap = (laps: Lap[]): Lap | null => laps.filter((l) => l.valid).reduce<Lap | null>((b, l) => (!b || l.seconds < b.seconds ? l : b), null);

/** Distance/time profile of a lap from its start crossing: cumulative metres and elapsed seconds per fix. */
export interface Profile { d: number[]; s: number[] }
export function lapProfile(fixes: Fix[], lap: Pick<Lap, 'startT' | 'from' | 'to'>): Profile {
  const seg = fixes.slice(lap.from + 1, lap.to + 1);
  const d: number[] = [0], s: number[] = [0];
  let prev: LatLon | null = null;
  for (const f of seg) {
    if (f.t < lap.startT) continue;
    if (prev) { d.push(d[d.length - 1] + haversine(prev, f)); s.push((f.t - lap.startT) / 1000); }
    else { d.push(0); s.push((f.t - lap.startT) / 1000); }
    prev = f;
  }
  return { d, s };
}

/** Time (s) the reference profile took to reach `dist` metres, linearly interpolated; null beyond its end. */
export function timeAtDistance(p: Profile, dist: number): number | null {
  if (!p.d.length || dist < 0 || dist > p.d[p.d.length - 1]) return null;
  for (let i = 1; i < p.d.length; i++) {
    if (p.d[i] >= dist) {
      const span = p.d[i] - p.d[i - 1];
      const k = span > 0 ? (dist - p.d[i - 1]) / span : 0;
      return p.s[i - 1] + k * (p.s[i] - p.s[i - 1]);
    }
  }
  return null;
}

/** Ghost delta: seconds ahead (negative) or behind (positive) the reference lap at the same distance. */
export function ghostDelta(best: Profile, distM: number, elapsedS: number): number | null {
  const ref = timeAtDistance(best, distM);
  return ref === null ? null : elapsedS - ref;
}

export interface LiveState { lapNo: number; elapsedS: number | null; lastLap: Lap | null; best: Lap | null; deltaS: number | null; laps: Lap[] }

/** Everything the live display shows, recomputed from the whole buffer (cheap at 1–10 Hz for a session). */
export function liveState(fixes: Fix[], line: TimingLine, opts: LapOpts = {}): LiveState {
  const laps = buildLaps(fixes, line, opts);
  const xs = detectCrossings(fixes, line, { minMs: opts.minMs });
  const best = bestLap(laps);
  const lastX = xs[xs.length - 1];
  const now = fixes[fixes.length - 1];
  if (!lastX || !now) return { lapNo: 0, elapsedS: null, lastLap: laps[laps.length - 1] ?? null, best, deltaS: null, laps };
  const elapsedS = (now.t - lastX.t) / 1000;
  let deltaS: number | null = null;
  if (best) {
    const cur = lapProfile(fixes, { startT: lastX.t, from: lastX.i - 1, to: fixes.length - 1 });
    deltaS = ghostDelta(lapProfile(fixes, best), cur.d[cur.d.length - 1], elapsedS);
  }
  return { lapNo: xs.length, elapsedS, lastLap: laps[laps.length - 1] ?? null, best, deltaS, laps };
}

/* ---------- stored traces ---------- */

/** One stored GPS sample: ms since session start, lat, lon (6 dp ≈ 0.1 m), speed m/s (1 dp), accuracy m (1 dp). */
export type TracePt = [number, number, number, number, number];
/** Most samples stored per session (≈ 30 min at 1 Hz; denser traces are downsampled). */
export const MAX_TRACE_POINTS = 2000;
/** Most sector lines per session. */
export const MAX_SECTORS = 5;
/** Most laps stored per session. */
export const MAX_SESSION_LAPS = 200;

const r1 = (x: number) => Math.round(x * 10) / 10;
const r6 = (x: number) => Math.round(x * 1e6) / 1e6;

/** Evenly thin a list to at most `max` items, always keeping the first and last. */
export function downsample<T>(xs: T[], max: number): T[] {
  if (xs.length <= max) return xs.slice();
  if (max < 2) return xs.slice(0, max);
  const out: T[] = [];
  for (let k = 0; k < max; k++) out.push(xs[Math.round((k * (xs.length - 1)) / (max - 1))]);
  return out;
}

/** Compact, capped trace for storage. Speed falls back to distance / time when the receiver gave none. */
export function toTrace(fixes: Fix[], max = MAX_TRACE_POINTS): TracePt[] {
  if (!fixes.length) return [];
  const t0 = fixes[0].t;
  const pts = fixes.map((f, i): TracePt => {
    let sp = f.speed;
    if (sp === null || !Number.isFinite(sp) || sp < 0) { const p = fixes[i - 1]; sp = p && f.t > p.t ? haversine(p, f) / ((f.t - p.t) / 1000) : 0; }
    return [Math.round(f.t - t0), r6(f.lat), r6(f.lon), r1(sp), r1(f.accuracy)];
  });
  return downsample(pts, max);
}

export interface SpeedPoint { dM: number; mps: number }
/** Speed against distance for one lap's slice of a stored trace (ms window, relative to the trace start). */
export function lapSpeedTrace(trace: TracePt[], fromMs: number, toMs: number, max = 300): SpeedPoint[] {
  const seg = trace.filter((p) => p[0] >= fromMs && p[0] <= toMs);
  const out: SpeedPoint[] = [];
  let d = 0;
  seg.forEach((p, i) => {
    if (i) d += haversine({ lat: seg[i - 1][1], lon: seg[i - 1][2] }, { lat: p[1], lon: p[2] });
    out.push({ dM: d, mps: p[3] });
  });
  return downsample(out, max);
}

export function minMax(xs: number[]): { min: number; max: number } | null {
  if (!xs.length) return null;
  return { min: Math.min(...xs), max: Math.max(...xs) };
}

/* ---------- export ---------- */

const esc = (s: string) => s.replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' })[c] as string);

/** GPX 1.1 track of a stored trace. `startIso` is the session's wall-clock start. */
export function toGpx(name: string, startIso: string, trace: TracePt[]): string {
  const t0 = Date.parse(startIso);
  const ok = Number.isFinite(t0);
  const pts = trace.map((p) => `      <trkpt lat="${p[1]}" lon="${p[2]}">${ok ? `<time>${new Date(t0 + p[0]).toISOString()}</time>` : ''}<hdop>${p[4]}</hdop><extensions><speed>${p[3]}</speed></extensions></trkpt>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="GT500 Companion" xmlns="http://www.topografix.com/GPX/1/1">\n  <trk><name>${esc(name)}</name>\n    <trkseg>\n${pts.join('\n')}\n    </trkseg>\n  </trk>\n</gpx>\n`;
}

/** CSV of a stored trace with the lap each sample belongs to (blank outside laps). */
export function traceCsv(trace: TracePt[], laps: { n: number; startMs: number; endMs: number }[]): string {
  const lapOf = (ms: number) => laps.find((l) => ms >= l.startMs && ms <= l.endMs)?.n ?? '';
  return ['t_ms,lap,lat,lon,speed_mps,accuracy_m', ...trace.map((p) => `${p[0]},${lapOf(p[0])},${p[1]},${p[2]},${p[3]},${p[4]}`)].join('\r\n') + '\r\n';
}

/* ---------- synthetic circuits (tests and demos) ---------- */

/**
 * A synthetic oval-ish circuit: a circle of `radiusM` around `centre`, driven anticlockwise at `mps`, sampled at `hz`.
 * `jitterM` adds deterministic pseudo-random position noise; `startAngle` is where the trace begins (radians, 0 = east).
 */
export function syntheticCircuit(o: { laps: number; radiusM?: number; mps?: number; hz?: number; accuracy?: number; jitterM?: number; centre?: LatLon; startAngle?: number; t0?: number; clockwise?: boolean }): Fix[] {
  const { laps, radiusM = 300, mps = 40, hz = 1, accuracy = 4, jitterM = 0, centre = { lat: 36.584, lon: -121.753 }, startAngle = -Math.PI / 2 + 0.3, t0 = 1_700_000_000_000, clockwise = false } = o;
  const P = projector(centre);
  const lapS = (2 * Math.PI * radiusM) / mps;
  const n = Math.ceil(laps * lapS * hz);
  let seed = 7;
  const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647 - 0.5; };
  const out: Fix[] = [];
  for (let i = 0; i <= n; i++) {
    const tt = i / hz;
    const ang = startAngle + (clockwise ? -1 : 1) * (mps * tt) / radiusM;
    const p = P.toLatLon({ x: radiusM * Math.cos(ang) + jitterM * rnd() * 2, y: radiusM * Math.sin(ang) + jitterM * rnd() * 2 });
    out.push({ t: t0 + tt * 1000, lat: p.lat, lon: p.lon, accuracy, speed: mps });
  }
  return out;
}

/** A radial line across the synthetic circuit at `angle` (from inside to outside the circle). */
export function radialLine(angle: number, o: { radiusM?: number; centre?: LatLon; halfWidth?: number; dir?: 1 | -1 | 0 } = {}): TimingLine {
  const { radiusM = 300, centre = { lat: 36.584, lon: -121.753 }, halfWidth = 20, dir = 0 } = o;
  const P = projector(centre);
  const at = (r: number) => P.toLatLon({ x: r * Math.cos(angle), y: r * Math.sin(angle) });
  return { a: at(radiusM - halfWidth), b: at(radiusM + halfWidth), dir };
}

/* ---------- nearest known facility (hint only) ---------- */

/**
 * The nearest track facility within `maxM` of `pos`, as a hint ("you seem to be at …"). Facility points are map
 * coordinates with up to ~1 km error and are never turned into a timing line.
 */
export function nearestFacility<T extends { facility: LatLon | null }>(pos: LatLon, list: T[], maxM = 5000): { track: T; distM: number } | null {
  let best: { track: T; distM: number } | null = null;
  for (const t of list) {
    if (!t.facility) continue;
    const d = haversine(pos, t.facility);
    if (d <= maxM && (!best || d < best.distM)) best = { track: t, distM: d };
  }
  return best;
}

/* ---------- session building ---------- */

/** Format seconds as m:ss.mmm (laps are stored in the Track log's text format). */
export function fmtLap(sec: number): string {
  // Round to the millisecond first so 59.9996 s carries into the minute ("1:00.000", not "0:60.000").
  const s = Math.round(sec * 1000) / 1000;
  const m = Math.floor(s / 60);
  const r = s - m * 60;
  return `${m}:${r.toFixed(3).padStart(6, '0')}`;
}

/** Track-log fields for a finished lap-timer session: valid laps as text (with sectors), plus GPS provenance. */
export function sessionFromFixes(fixes: Fix[], line: TimingLine, sectors: TimingLine[], opts: LapOpts = {}) {
  const laps = buildLaps(fixes, line, { ...opts, sectors });
  if (!fixes.length) return null;
  const t0 = fixes[0].t;
  const text = laps.filter((l) => l.valid).map((l) => fmtLap(l.seconds) + (l.sectors ? ` | ${l.sectors.map((x) => x.toFixed(2)).join(' ')}` : '')).join('\n');
  return {
    laps: laps.slice(0, MAX_SESSION_LAPS),
    text,
    gps: {
      startIso: new Date(t0).toISOString(), line, sectors: sectors.slice(0, MAX_SECTORS),
      laps: laps.slice(0, MAX_SESSION_LAPS).map((l) => ({ n: l.n, seconds: Math.round(l.seconds * 1000) / 1000, sectors: l.sectors ? l.sectors.map((x) => Math.round(x * 1000) / 1000) : null, accuracyM: r1(l.worstAccuracyM), startMs: Math.round(l.startT - t0), endMs: Math.round(l.endT - t0), valid: l.valid })),
      trace: toTrace(fixes),
    },
  };
}

/** Keep traces only on the newest `keep` GPS sessions (older ones keep their laps) so local storage stays small. */
export function pruneTraces<T extends { date: string; gps?: { trace: TracePt[]; startIso: string } }>(list: T[], keep = 10): T[] {
  const withTrace = list.filter((s) => s.gps && s.gps.trace.length).sort((a, b) => (b.gps?.startIso ?? '').localeCompare(a.gps?.startIso ?? ''));
  const drop = new Set(withTrace.slice(keep));
  return list.map((s) => (drop.has(s) && s.gps ? { ...s, gps: { ...s.gps, trace: [] } } : s));
}

/* ---------- sourced start/finish lines ---------- */

/** Sourced lines for one track (optionally one configuration, case-insensitive). */
export function linesForTrack<T extends { trackId: string; configuration: string }>(list: T[], trackId: string, configuration?: string): T[] {
  return list.filter((l) => l.trackId === trackId && (configuration === undefined || l.configuration.toLowerCase() === configuration.toLowerCase()));
}

/** A sourced line record as lap-timer lines (start/finish + sectors). A missing direction counts both ways. */
export function sourcedTimingLines(l: { a: LatLon; b: LatLon; direction?: 1 | -1; sectors: { a: LatLon; b: LatLon }[] }): { line: TimingLine; sectors: TimingLine[] } {
  return { line: { a: { ...l.a }, b: { ...l.b }, dir: l.direction ?? 0 }, sectors: l.sectors.slice(0, MAX_SECTORS).map((s) => ({ a: { ...s.a }, b: { ...s.b }, dir: 0 })) };
}

/** True when a source URL is OpenStreetMap (its data needs the "© OpenStreetMap contributors" credit). */
export function isOsmSource(url: string): boolean {
  try { const h = new URL(url).hostname.toLowerCase(); return h === 'openstreetmap.org' || h.endsWith('.openstreetmap.org') || h === 'osm.org' || h.endsWith('.osm.org'); } catch { return false; }
}
