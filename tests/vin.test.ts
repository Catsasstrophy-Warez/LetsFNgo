import { describe, expect, it } from 'vitest';
import { computeCheckDigit, decodeVin } from '../src/lib/vin';
import { sampleVins } from '../src/data/vin';

describe('computeCheckDigit', () => {
  it('matches known-good sample GT500 VINs', () => {
    expect(computeCheckDigit('1FA6P8SJ1L5504855')).toBe('1');
    expect(computeCheckDigit('1FA6P8SJ6M5500608')).toBe('6');
  });
  it('produces X when remainder is 10 (NHTSA example)', () => {
    expect(computeCheckDigit('1M8GDM9AXKP042788')).toBe('X');
  });
  it('returns null for wrong length or invalid characters', () => {
    expect(computeCheckDigit('1FA6P8SJ1L550485')).toBeNull();
    expect(computeCheckDigit('1FA6P8SJ1L55O4855')).toBeNull();
  });
});

describe('decodeVin', () => {
  it('decodes sample GT500 VINs', () => {
    for (const v of sampleVins) {
      const d = decodeVin(v);
      expect(d.valid).toBe(true);
      expect(d.isGT500).toBe(true);
    }
    expect(decodeVin('1FA6P8SJ1L5504855').year).toBe(2020);
    expect(decodeVin('1FA6P8SJ6M5500608').year).toBe(2021);
  });
  it('normalizes case, spaces and dashes', () => {
    expect(decodeVin(' 1fa6p8sj1l-5504855 ').valid).toBe(true);
  });
  it('rejects a bad check digit', () => {
    const d = decodeVin('1FA6P8SJ2L5504855');
    expect(d.valid).toBe(false);
    expect(d.checkDigit.expected).toBe('1');
  });
  it('flags a valid non-GT500 VIN', () => {
    const d = decodeVin('1M8GDM9AXKP042788');
    expect(d.valid).toBe(true);
    expect(d.isGT500).toBe(false);
    expect(d.warnings.length).toBeGreaterThan(0);
  });
  it('flags a GT350 code', () => {
    const vin = '1FA6P8JZ?L5500000';
    const fixed = vin.replace('?', computeCheckDigit(vin.replace('?', '0'))!);
    const d = decodeVin(fixed);
    expect(d.valid).toBe(true);
    expect(d.isGT500).toBe(false);
    expect(d.fields.find((f) => f.position === '5–7')!.meaning).toMatch(/GT350/);
  });
  it('rejects I/O/Q and wrong length', () => {
    expect(decodeVin('1FA6P8SJ1L550485').valid).toBe(false);
    expect(decodeVin('1FA6P8SJ1L55Q4855').errors.join()).toMatch(/I, O or Q/);
  });
  it('decodes a 2022 year code', () => {
    const base = '1FA6P8SJ0N5500001';
    const cd = computeCheckDigit(base)!;
    const d = decodeVin(base.slice(0, 8) + cd + base.slice(9));
    expect(d.year).toBe(2022);
    expect(d.isGT500).toBe(true);
  });
});
