import type { ModelYear } from '../data/types';

const TRANSLIT: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8,
  J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9,
  S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9,
};
const WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

export function normalizeVin(input: string): string {
  return input.toUpperCase().replace(/[\s-]/g, '');
}

/** NHTSA (49 CFR 565) check digit for a 17-char VIN. Returns null if a character is invalid. */
export function computeCheckDigit(vin: string): string | null {
  const v = normalizeVin(vin);
  if (v.length !== 17) return null;
  let sum = 0;
  for (let i = 0; i < 17; i++) {
    const ch = v[i];
    let n: number | undefined;
    if (/[0-9]/.test(ch)) n = Number(ch);
    else n = TRANSLIT[ch];
    if (n === undefined) return null;
    sum += n * WEIGHTS[i];
  }
  const r = sum % 11;
  return r === 10 ? 'X' : String(r);
}

export interface VinDecode {
  vin: string;
  valid: boolean;
  errors: string[];
  checkDigit: { expected: string | null; actual: string | null; ok: boolean };
  isGT500: boolean;
  warnings: string[];
  fields: { position: string; value: string; meaning: string }[];
  year: ModelYear | null;
}

const YEARS: Record<string, ModelYear> = { L: 2020, M: 2021, N: 2022 };

export function decodeVin(input: string): VinDecode {
  const vin = normalizeVin(input);
  const errors: string[] = [];
  const warnings: string[] = [];
  if (vin.length !== 17) errors.push(`VIN must be 17 characters (got ${vin.length}).`);
  if (/[IOQ]/.test(vin)) errors.push('VINs never contain I, O or Q.');
  if (/[^A-Z0-9]/.test(vin)) errors.push('VIN may contain only letters and digits.');
  const expected = errors.length ? null : computeCheckDigit(vin);
  const actual = vin.length >= 9 ? vin[8] : null;
  const checkOk = expected !== null && expected === actual;
  if (!errors.length && !checkOk) errors.push(`Check digit mismatch: position 9 is "${actual}", expected "${expected}".`);

  const fields: VinDecode['fields'] = [];
  let year: ModelYear | null = null;
  let isGT500 = false;
  if (vin.length === 17) {
    const wmi = vin.slice(0, 3);
    fields.push({ position: '1–3', value: wmi, meaning: wmi === '1FA' ? 'Ford Motor Co., USA, passenger car' : 'Not 1FA — not a Ford USA passenger car' });
    fields.push({ position: '4', value: vin[3], meaning: 'Restraint system code (unverified)' });
    const line = vin.slice(4, 7);
    fields.push({ position: '5–7', value: line, meaning: line === 'P8S' ? 'Shelby GT500 fastback' : line === 'P8J' ? 'Shelby GT350 (not a GT500)' : 'Not a GT500 line/body code' });
    fields.push({ position: '8', value: vin[7], meaning: vin[7] === 'J' ? '5.2L supercharged V8 (Predator)' : 'Not the GT500 engine code (J)' });
    fields.push({ position: '9', value: vin[8], meaning: checkOk ? 'Check digit — valid' : `Check digit — invalid (expected ${expected ?? '?'})` });
    year = YEARS[vin[9]] ?? null;
    fields.push({ position: '10', value: vin[9], meaning: year ? `Model year ${year}` : 'Not a 2020–2022 year code (L/M/N)' });
    fields.push({ position: '11', value: vin[10], meaning: vin[10] === '5' ? 'Flat Rock, MI (inferred)' : 'Not the expected plant code 5' });
    fields.push({ position: '12–17', value: vin.slice(11), meaning: 'Sequential serial number' });

    isGT500 = wmi === '1FA' && line === 'P8S' && vin[7] === 'J' && year !== null;
    if (!isGT500) warnings.push('This VIN does not match the 2020–2022 Shelby GT500 pattern 1FA?P8SJ?[L/M/N]5.');
    else if (vin[10] !== '5') warnings.push('Plant code is not 5 (Flat Rock) — unusual for a GT500.');
  }
  return { vin, valid: errors.length === 0, errors, checkDigit: { expected, actual, ok: checkOk }, isGT500, warnings, fields, year };
}
