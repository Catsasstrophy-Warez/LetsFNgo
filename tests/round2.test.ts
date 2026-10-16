import { describe, expect, it } from 'vitest';
import { specs } from '../src/data/specs';
import { competitors } from '../src/data/competitors';
import { recalls } from '../src/data/recalls';
import { photos, audio } from '../src/data/media';
import { maintenance } from '../src/data/maintenance';
import { colors } from '../src/data/colors';

describe('round 2 data', () => {
  it('has TREMEC gear ratios and 180 mph limit', () => {
    expect(specs.find((s) => s.id === 'gear-ratios')!.value).toContain('3.14 / 2.05 / 1.43 / 1.10 / 0.86 / 0.68 / 0.56');
    expect(specs.find((s) => s.id === 'top-speed')!.value).toBe(180);
  });
  it('marks every competitor spec sheet unverified', () => {
    for (const c of competitors) if (c.sheet) expect(c.sheet.confidence).toBe('unverified');
  });
  it('lists NHTSA campaigns with VIN-check framing', () => {
    const n = recalls.filter((r) => r.kind === 'nhtsa-recall');
    expect(n.length).toBe(16);
    for (const r of n) { expect(r.campaign).toMatch(/^\d{2}V\d{6}$/); expect(r.summary).toMatch(/VIN check required/); }
    expect(recalls.some((r) => r.campaign === 'ODI 11522730')).toBe(true);
  });
  it('credits every Commons photo and audio clip', () => {
    expect(photos.length).toBe(7);
    for (const p of photos) {
      expect(p.thumb).toMatch(/^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/thumb\//);
      expect(p.license).toBe('CC BY-SA 4.0');
      expect(p.author).toBeTruthy();
    }
    for (const a of audio) { expect(a.author).toBeTruthy(); expect(a.license).toMatch(/CC/); }
  });
  it('warns that XT-11-QDC is the wrong DCT fluid and models oil capacity conflict', () => {
    expect(maintenance.find((m) => m.id === 'dct-fluid')!.warning).toMatch(/XT-11-QDC/);
    expect(maintenance.find((m) => m.id === 'oil-cap')!.conflicts!.length).toBe(3);
  });
  it('uses corrected paint codes (not PP / KU)', () => {
    expect(colors.find((c) => c.id === 'grabber-lime')!.code).toMatch(/^F9/);
    expect(colors.find((c) => c.id === 'twister-orange')!.code).toMatch(/^CA/);
  });
});
