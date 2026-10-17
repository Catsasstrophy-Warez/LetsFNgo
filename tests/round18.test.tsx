import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter, Route, Routes } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { TrackNoise } from '../src/components/TrackNoise';
import { specs } from '../src/data/specs';
import { partNumbers, partSlots } from '../src/data/parts';
import { maintenance } from '../src/data/maintenance';
import { tracks } from '../src/data/tracks';
import { SOURCED_SERVICE_PRICES, servicePricing } from '../src/lib/cost';
import { freshChecklist } from '../src/lib/preTrack';
import { en, type Lang, type MsgKey } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';

const wrap = (el: JSX.Element, lang: Lang = 'en', path = '/') => renderToString(
  <SettingsContext.Provider value={{ settings: { units: 'imperial', theme: 'dark', lang }, setSettings: () => undefined }}>
    <MemoryRouter initialEntries={[path]}><Routes><Route path="/" element={el} /></Routes></MemoryRouter>
  </SettingsContext.Provider>,
).replace(/<!-- -->/g, '');
async function page(name: string, lang: Lang = 'en') {
  const { PAGES } = await import('../src/App');
  const { default: P } = await PAGES[name as keyof typeof PAGES]() as { default: () => JSX.Element };
  return wrap(<P />, lang);
}
const part = (id: string) => partNumbers.find((p) => p.id === id)!;
const laguna = tracks.find((t) => t.id === 'weathertech-raceway-laguna-seca')!;

describe('round 16 data', () => {
  it('OEM tire fitment from Michelin, reported; Cup 2 load index not stated as confirmed', () => {
    const f = specs.find((s) => s.id === 'tire-f-oem')!, r = specs.find((s) => s.id === 'tire-r-oem')!;
    expect(f).toMatchObject({ value: '305/30ZR20 XL 103Y', confidence: 'reported' });
    expect(r).toMatchObject({ value: '315/30ZR20 XL 104Y', confidence: 'reported' });
    expect(f.source).toMatch(/^https:\/\/www\.michelinman\.com\//);
    expect(f.note).toMatch(/Cup 2 load index for the GT500 is not confirmed/);
    expect(f.context).toMatch(/Carbon Fiber Track Package/);
  });
  it('XT-14-L listing price is unverified, per listing (pack size unclear), never per quart', () => {
    const p = part('xt-14-l').price!;
    expect(p).toMatchObject({ value: 117.59, per: 'listing', confidence: 'unverified', dateSeen: '2026-10-17' });
    expect(p.context).toMatch(/pack size unclear/);
    const sp = servicePricing('r-dct');
    expect(sp.price).toBeNull();
    expect(sp.parts.find((x) => x.part.id === 'xt-14-l')!.reason).toBe('unclear-pack');
    expect(SOURCED_SERVICE_PRICES['r-dct']).toBeUndefined();
    expect(Object.keys(SOURCED_SERVICE_PRICES)).toHaveLength(0);
  });
  it('Hawk front pads are aftermarket, unverified, with ranges kept as conflicts', () => {
    for (const id of ['hb928b-644', 'hb928g-644', 'hb928u-644']) {
      const p = part(id);
      expect(p.brand).toBe('Hawk'); expect(p.category).toBe('Brake pad (aftermarket)'); expect(p.description).toMatch(/not a Ford OEM part/);
      expect(p.confidence).toBe('unverified'); expect(p.price!.confidence).toBe('unverified');
      expect(p.reminderIds).toEqual([]);
    }
    expect(part('hb928b-644').price!.conflicts!.map((c) => c.value)).toEqual([294.29, 310.99]);
    expect(part('hb928g-644').price!.conflicts!.map((c) => c.value)).toEqual([717]);
    expect(part('hb928u-644').price!.value).toBe(544.99);
    expect(partSlots).toContain('Brake pads & rotors (Ford OEM part numbers)');
  });
  it('no currency conversion: no Cup 2 price and every part price is the USD figure as listed', () => {
    const all = partNumbers.flatMap((p) => (p.price ? [p.price.value, ...(p.price.conflicts ?? []).map((c) => c.value)] : []));
    expect(all).not.toContain(916); expect(all).not.toContain(1022);
    expect(JSON.stringify(partNumbers)).not.toMatch(/CAD|lacroix/i);
    expect(JSON.stringify(specs)).not.toMatch(/lacroix/i);
  });
  it('Laguna Seca noise limit 92 dB with 90 / 103 dB event-day variants; other tracks unset', () => {
    expect(laguna.noiseLimit).toMatchObject({ value: 92, confidence: 'reported' });
    expect(laguna.noiseLimit!.conflicts!.map((c) => c.value)).toEqual([90, 103]);
    expect(tracks.filter((t) => t.noiseLimit).map((t) => t.id)).toEqual([laguna.id]);
  });
  it('oil capacity keeps its range and adds the 2020-supplement claim as unverified', () => {
    const o = maintenance.find((m) => m.id === 'oil-cap')!;
    expect(o.value).toBe('10–11.5');
    const c = o.conflicts!.find((x) => /2020 supplement/.test(String(x.value)))!;
    expect(c.confidence).toBe('unverified');
    expect(JSON.stringify(maintenance)).not.toMatch(/mustangspecs/i);
  });
});

describe('round 18 UI', () => {
  it('shows the noise limit with its source, and says when a track has none', () => {
    const h = wrap(<TrackNoise track={laguna} />);
    expect(h).toContain('Noise limit: 92 dB'); expect(h).toContain('90 dB'); expect(h).toContain('103 dB'); expect(h).toContain('motorsportreg.com');
    expect(wrap(<TrackNoise track={tracks.find((t) => t.id === 'road-america')!} />)).toContain(en['noise.none']);
    expect(wrap(<TrackNoise track={laguna} />, 'es')).toContain('Límite de ruido: 92 dB');
  });
  it('pre-track checklist asks to check the noise limit', () => {
    const tr = (k: MsgKey) => en[k];
    expect(freshChecklist(tr, { items: [] }).find((i) => i.id === 'ptc-noise')?.label).toBe(en['ptc.noise']);
  });
  it('Tires page lists the OEM fitment; Parts page shows aftermarket pads and the listing price caveat', async () => {
    const t = await page('Tires');
    expect(t).toContain('305/30ZR20 XL 103Y'); expect(t).toContain('315/30ZR20 XL 104Y'); expect(t).toContain(en['tires.oemNote']);
    const p = await page('Parts');
    expect(p).toContain('HB928U.644'); expect(p).toContain(en['parts.aftermarket']);
    expect(p).toContain('$117.59 per listing, pack size unclear');
    expect(await page('Parts', 'es')).toContain('por anuncio, tamaño del paquete poco claro');
  });
  it('every new key is translated to Spanish', () => {
    const keys = ['cost.partListing', 'cost.unclearPack', 'tires.oem', 'tires.oemNote', 'parts.aftermarket', 'parts.priceEach', 'parts.priceQuart', 'parts.priceListing', 'parts.otherPrices', 'noise.label', 'noise.other', 'noise.none', 'ptc.noise'] as MsgKey[];
    for (const k of keys) { expect(en[k], k).toBeTruthy(); expect(es[k], k).toBeTruthy(); expect(es[k], k).not.toBe(en[k]); }
  });
});
