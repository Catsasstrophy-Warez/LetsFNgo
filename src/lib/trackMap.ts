/**
 * Track map math for a stored GPS session: an equirectangular projection auto-fitted to an SVG box (no tiles, no
 * network), speed bins for colouring, the sector-times table with best and theoretical-best, and nearest-point
 * lookup for tap-to-inspect. Pure functions so the rules are unit-tested.
 */
import { haversine } from './gps';
import type { LatLon, TracePt, XY } from './lapTimer';

/**
 * Colour-blind-safe sequential palette (viridis, darkest step dropped so every bin stands out on the dark theme as
 * well; the map also draws a neutral underlay). Ordered slow → fast; distinguishable with protan/deutan/tritan vision.
 */
export const SPEED_COLORS = ['#3e4a89', '#26828e', '#35b779', '#90d743', '#fde725'] as const;

const rad = (d: number) => (d * Math.PI) / 180;

/**
 * Equirectangular fit: x = lon·cos(mid-latitude), y = −lat, scaled uniformly (aspect kept) and centred in a W×H box
 * with `pad` on every side. Returns null when there are no points.
 */
export function fitMap(points: LatLon[], W: number, H: number, pad = 12): ((p: LatLon) => XY) | null {
  if (!points.length) return null;
  let minLat = Infinity, maxLat = -Infinity, minLon = Infinity, maxLon = -Infinity;
  for (const p of points) { minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat); minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon); }
  const k = Math.cos(rad((minLat + maxLat) / 2));
  const dx = (maxLon - minLon) * k, dy = maxLat - minLat;
  const span = Math.max(dx, dy);
  const s = span > 0 ? Math.min((W - 2 * pad) / (dx || span), (H - 2 * pad) / (dy || span)) : 1;
  const ox = (W - dx * s) / 2, oy = (H - dy * s) / 2;
  return (p) => ({ x: ox + (p.lon - minLon) * k * s, y: oy + (maxLat - p.lat) * s });
}

export interface SpeedBins { edges: number[]; /** Bin index (0 … n−1) for a speed. */ of: (v: number) => number }
/** `n` equal-width bins between the slowest and fastest speed (edges has n + 1 values). */
export function speedBins(values: number[], n = SPEED_COLORS.length): SpeedBins {
  const fin = values.filter(Number.isFinite);
  const lo = fin.length ? Math.min(...fin) : 0, hi = fin.length ? Math.max(...fin) : 0;
  const w = hi > lo ? (hi - lo) / n : 0;
  const edges = Array.from({ length: n + 1 }, (_, i) => (w ? lo + i * w : lo));
  return { edges, of: (v) => (w ? Math.max(0, Math.min(n - 1, Math.floor((v - lo) / w))) : 0) };
}

export interface MapPoint { lat: number; lon: number; mps: number; /** ms since the lap's start crossing. */ ms: number; /** metres since the lap start. */ dM: number }
/** The stored samples inside one lap, with time and distance from the lap start. */
export function lapPoints(trace: TracePt[], startMs: number, endMs: number): MapPoint[] {
  const seg = trace.filter((p) => p[0] >= startMs && p[0] <= endMs);
  let d = 0;
  return seg.map((p, i) => {
    if (i) d += haversine({ lat: seg[i - 1][1], lon: seg[i - 1][2] }, { lat: p[1], lon: p[2] });
    return { lat: p[1], lon: p[2], mps: p[3], ms: p[0] - startMs, dM: d };
  });
}

/** Index of the point nearest to (x, y) in projected coordinates, or −1 for an empty list. */
export function nearestIndex(pts: XY[], x: number, y: number): number {
  let best = -1, bd = Infinity;
  pts.forEach((p, i) => { const d = (p.x - x) ** 2 + (p.y - y) ** 2; if (d < bd) { bd = d; best = i; } });
  return best;
}

export interface SectorRow { n: number; sectors: number[]; total: number; valid: boolean }
export interface SectorTable { count: number; rows: SectorRow[]; /** Best time per sector over valid laps (null when no valid lap has it). */ best: (number | null)[]; /** Sum of best sectors; null unless every sector has a best. */ theoretical: number | null; bestLap: number | null }
/**
 * Sector table from stored laps. Only laps whose sector list has the most common length are tabulated; refused
 * (invalid) laps are listed but never count towards best or theoretical best.
 */
export function sectorTable(laps: { n: number; seconds: number; sectors: number[] | null; valid: boolean }[]): SectorTable {
  const withSec = laps.filter((l) => l.sectors && l.sectors.length >= 2);
  const freq = new Map<number, number>();
  for (const l of withSec) freq.set(l.sectors!.length, (freq.get(l.sectors!.length) ?? 0) + 1);
  const count = [...freq.entries()].sort((a, b) => b[1] - a[1] || b[0] - a[0])[0]?.[0] ?? 0;
  const rows = withSec.filter((l) => l.sectors!.length === count).map((l) => ({ n: l.n, sectors: l.sectors!.slice(), total: l.seconds, valid: l.valid }));
  const valid = rows.filter((r) => r.valid);
  const best = Array.from({ length: count }, (_, i) => (valid.length ? Math.min(...valid.map((r) => r.sectors[i])) : null));
  const theoretical = count && best.every((b) => b !== null) ? Math.round((best as number[]).reduce((a, b) => a + b, 0) * 1000) / 1000 : null;
  const bestLap = valid.length ? Math.min(...valid.map((r) => r.total)) : null;
  return { count, rows, best, theoretical, bestLap };
}
