import { specs } from '../data/specs';

/** Inches per mile / (60 min × 2π)… folded: mph = rpm × diameter(in) / (overall ratio × 336.13). */
const K = 63360 / (60 * Math.PI);

export interface TireSize { width: number; aspect: number; rim: number }

/** Parse a metric tire size such as "315/30R20" or "305/30ZR20". */
export function parseTireSize(s: string): TireSize | null {
  const m = /^\s*(\d{3})\s*\/\s*(\d{2})\s*Z?R\s*(\d{2})\s*$/i.exec(s);
  if (!m) return null;
  const t = { width: Number(m[1]), aspect: Number(m[2]), rim: Number(m[3]) };
  return t.width > 0 && t.aspect > 0 && t.rim > 0 ? t : null;
}

/** Unloaded overall diameter in inches (geometric — real rolling radius is a little smaller). */
export function tireDiameterIn(t: TireSize): number {
  return t.rim + (2 * t.width * (t.aspect / 100)) / 25.4;
}

export function mphAt(rpm: number, gear: number, finalDrive: number, diameterIn: number): number {
  return (rpm * diameterIn) / (gear * finalDrive * K);
}

export function rpmAt(mph: number, gear: number, finalDrive: number, diameterIn: number): number {
  return (mph * gear * finalDrive * K) / diameterIn;
}

/** Parse the sourced TREMEC ratio string ("3.14 / 2.05 / … · R 2.76") into forward ratios. */
export function parseRatios(s: string): number[] {
  return s.split('·')[0].split('/').map((x) => Number(x.trim())).filter((n) => Number.isFinite(n) && n > 0);
}

const spec = (id: string) => specs.find((x) => x.id === id)!;
export const RATIO_SPEC = spec('gear-ratios');
export const DIFF_SPEC = spec('diff');
export const REDLINE_SPEC = spec('redline');
export const TOP_SPEED_SPEC = spec('top-speed');
export const TIRE_SPECS = [spec('tire-r'), spec('tire-f')];

export const GT500_RATIOS = parseRatios(String(RATIO_SPEC.value));
export const GT500_FINAL = Number(/[\d.]+/.exec(String(DIFF_SPEC.value))![0]);
export const GT500_REDLINE = Number(REDLINE_SPEC.value);
export const GT500_REAR_TIRE = String(TIRE_SPECS[0].value);
