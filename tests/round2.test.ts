import { describe, expect, it } from 'vitest';
import { specs } from '../src/data/specs';
import { competitors } from '../src/data/competitors';
import { recalls } from '../src/data/recalls';
import { photos, audio, media } from '../src/data/media';
import { production } from '../src/data/production';
import { prices } from '../src/data/pricing';
import { packages } from '../src/data/packages';
import { maintenance } from '../src/data/maintenance';
import { colors } from '../src/data/colors';

describe('round 2 data', () => {
  it('has TREMEC gear ratios and 180 mph limit', () => {
    expect(specs.find((s) => s.id === 'gear-ratios')!.value).toContain('3.14 / 2.05 / 1.43 / 1.10 / 0.86 / 0.68 / 0.56');
    expect(specs.find((s) => s.id === 'top-speed')!.value).toBe(180);
  });
  it('uses sourced round-3 competitor sheets; unverified rows are hidden', () => {
    const sheets = competitors.flatMap((c) => (c.sheet ? [c.sheet] : []));
    expect(sheets.length).toBe(10);
    for (const s of sheets) {
      expect(s.note ?? '').not.toMatch(/from memory/i);
      if (s.confidence === 'unverified') expect(s.hidden).toBe(true);
      else expect(s.hidden).toBeFalsy();
    }
    expect(competitors.find((c) => c.id === 'redeye')!.sheet!.hidden).toBe(true);
    expect(competitors.find((c) => c.id === 'jailbreak')!.sheet!.hidden).toBe(true);
    expect(competitors.find((c) => c.id === 'hellcat')!.sheet).toBeUndefined();
    expect(sheets.every((s) => s.priceUsd === null)).toBe(true);
  });
  it('round-3 gap fills', () => {
    expect(specs.find((s) => s.id === 'bore-stroke')).toMatchObject({ value: expect.stringContaining('94 × 93 mm'), confidence: 'reported' });
    // Round 4 replaced the unverified 0.035–0.039 range with the 2021 supplement figure; the old range stays as a secondary value.
    expect(maintenance.find((m) => m.id === 'plugs')!.conflicts!.find((c) => String(c.value).includes('0.035–0.039'))!.confidence).toBe('unverified');
    const h = production.find((p) => p.id === 'heritage')!;
    expect(h.value).toBe(225); expect(h.conflicts!.map((c) => c.value)).toContain('~255');
    expect(prices.find((p) => p.id === 'p22-heritage')!.value).toBe(76695);
    expect(packages.find((p) => p.id === 'heritage-pkg')!.priceConflicts!.some((c) => c.value === 10000)).toBe(true);
    expect(media.filter((m) => m.id.startsWith('r3v')).length).toBe(13);
    expect(media.filter((m) => m.category === 'Onboard').length).toBe(6);
  });
  it('lists NHTSA campaigns with VIN-check framing', () => {
    const n = recalls.filter((r) => r.kind === 'nhtsa-recall');
    expect(n.length).toBe(16);
    for (const r of n) { expect(r.campaign).toMatch(/^\d{2}V\d{6}$/); expect(r.appliesToGT500).toMatch(/^(yes|likely|no|vin)$/); }
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
