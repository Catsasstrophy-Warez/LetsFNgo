/**
 * Classic drag-strip rules of thumb. These are rough ESTIMATES for a well-hooked car;
 * they ignore traction, gearing, DA and driver. Weight is race weight (car + driver), hp at the crank.
 */
export interface QuarterEstimate { et: number; mph: number }

export function haleQuarter(weightLb: number, hp: number): QuarterEstimate | null {
  if (!(weightLb > 0 && hp > 0)) return null;
  return { et: 5.825 * Math.cbrt(weightLb / hp), mph: 234 * Math.cbrt(hp / weightLb) };
}

export function foxQuarter(weightLb: number, hp: number): QuarterEstimate | null {
  if (!(weightLb > 0 && hp > 0)) return null;
  return { et: 6.29 * Math.cbrt(weightLb / hp), mph: 224 * Math.cbrt(hp / weightLb) };
}

export interface PowerToWeight { lbPerHp: number; hpPerTon: number; kgPerKw: number; wPerKg: number }

export function powerToWeight(weightLb: number, hp: number): PowerToWeight | null {
  if (!(weightLb > 0 && hp > 0)) return null;
  const kg = weightLb * 0.45359237;
  const kw = hp * 0.7457;
  return { lbPerHp: weightLb / hp, hpPerTon: hp / (weightLb / 2000), kgPerKw: kg / kw, wPerKg: (kw * 1000) / kg };
}
