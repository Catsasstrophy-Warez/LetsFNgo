import { mphAt, parseTireSize, rpmAt, tireDiameterIn, type TireSize } from './gearing';

/** Revolutions per mile from geometric diameter (inches). */
export const revsPerMile = (diameterIn: number) => 63360 / (Math.PI * diameterIn);

export interface TireInfo { size: TireSize; diameterIn: number; sidewallIn: number; widthIn: number; circumferenceIn: number; revsPerMile: number }
export function tireInfo(s: string): TireInfo | null {
  const size = parseTireSize(s);
  if (!size) return null;
  const d = tireDiameterIn(size);
  return { size, diameterIn: d, sidewallIn: (size.width * size.aspect / 100) / 25.4, widthIn: size.width / 25.4, circumferenceIn: Math.PI * d, revsPerMile: revsPerMile(d) };
}

export interface TireCompare {
  stock: TireInfo; alt: TireInfo;
  diameterPct: number;
  /** Actual speed when the speedometer (calibrated to stock) reads `indicated` mph. */
  actualAt: (indicated: number) => number;
  /** Speedometer error in percent: positive = reads low (you're faster than shown). */
  speedoErrorPct: number;
  /** Effective final drive with the alternate tire (same road speed per engine rev as stock with this ratio). */
  effectiveFinal: number;
  rpmAt: (mph: number, gear: number) => { stock: number; alt: number };
  topSpeedPerGear: { gear: number; stock: number; alt: number }[];
}

/** Compare a stock and an alternate tire with the given ratios. Geometric diameters; real rolling radius is smaller. */
export function compareTires(stockSize: string, altSize: string, ratios: number[], finalDrive: number, redline: number): TireCompare | null {
  const stock = tireInfo(stockSize), alt = tireInfo(altSize);
  if (!stock || !alt || finalDrive <= 0) return null;
  const k = alt.diameterIn / stock.diameterIn;
  return {
    stock, alt,
    diameterPct: (k - 1) * 100,
    actualAt: (indicated) => indicated * k,
    speedoErrorPct: (k - 1) * 100,
    effectiveFinal: finalDrive / k,
    rpmAt: (mph, gear) => ({ stock: rpmAt(mph, gear, finalDrive, stock.diameterIn), alt: rpmAt(mph, gear, finalDrive, alt.diameterIn) }),
    topSpeedPerGear: ratios.map((g, i) => ({ gear: i + 1, stock: mphAt(redline, g, finalDrive, stock.diameterIn), alt: mphAt(redline, g, finalDrive, alt.diameterIn) })),
  };
}
