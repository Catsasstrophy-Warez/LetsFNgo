import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { recalls } from '../src/data/recalls';
import { auctionResults } from '../src/data/auctions';
import { BUYER_KEY, loadBuyer, normBuyer, saveBuyer, toggleCheck } from '../src/lib/buyer';
import { BUY_SECTIONS, buildChecklist, positionPrice, recallsFor } from '../src/lib/buyerGuide';
import { ALL_KEYS, SCHEMA_VERSION, makeBackup, migrate, restoreBackup, validateBackup } from '../src/lib/backup';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { search } from '../src/lib/search';
import { NAV } from '../src/App';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import Buy from '../src/pages/Buy';
import type { AuctionResult } from '../src/data/types';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });
beforeEach(() => store.clear());

const wrap = (el: JSX.Element, lang: 'en' | 'es' = 'en') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang }, setSettings: () => undefined }}><MemoryRouter>{el}</MemoryRouter></SettingsContext.Provider>,
);

describe('buyer checklist is built only from sourced records', () => {
  it('every item has an https source and a confidence, unique ids, known sections', () => {
    const items = buildChecklist(null);
    expect(items.length).toBeGreaterThan(20);
    for (const i of items) {
      expect(i.source).toMatch(/^https:\/\//);
      expect(['confirmed', 'reported', 'unverified']).toContain(i.confidence);
      expect(BUY_SECTIONS).toContain(i.section);
    }
    expect(new Set(items.map((i) => i.id)).size).toBe(items.length);
    for (const s of BUY_SECTIONS) expect(items.some((i) => i.section === s), s).toBe(true);
  });
  it('excludes recalls that do not apply to the GT500 and filters by year', () => {
    const ids = buildChecklist(null).map((i) => i.id);
    for (const r of recalls.filter((x) => x.appliesToGT500 === 'no')) expect(ids.some((id) => id.endsWith(`:${r.id}`))).toBe(false);
    expect(recallsFor(2020).map((r) => r.id)).toContain('n20V573000');
    expect(recallsFor(2022).map((r) => r.id)).not.toContain('n20V573000');
    expect(recallsFor(2022).map((r) => r.id)).toContain('n23V727000');
    expect(buildChecklist(2020).map((i) => i.id)).toContain('paint:twister-orange');
  });
});

describe('price positioning (counts only, no model)', () => {
  const r = (id: string, price: number, mileage: number, extra: Partial<AuctionResult> = {}): AuctionResult => ({ id, date: '2025-01', venue: null, year: 2020, mileage, price, outcome: 'sold', cftp: null, heritage: null, description: '', source: 'https://example.com/', confidence: 'reported', ...extra });
  const data = [r('a', 80000, 1000), r('b', 90000, 5000), r('c', 100000, 20000), r('o', 200000, 10, { outlier: 'x' }), r('n', 95000, 100, { outcome: 'no-sale' }), r('y', 70000, 10, { year: 2021 })];
  it('counts sales below/above and lists nearest mileage', () => {
    const p = positionPrice(92000, 2020, 4000, data, []);
    expect(p.points.map((x) => x.id)).toEqual(['a', 'b', 'c']);
    expect([p.below, p.above, p.same]).toEqual([2, 1, 0]);
    expect(p.median).toBe(90000);
    expect(p.nearMiles[0].id).toBe('b');
    expect(positionPrice(92000, 2020, null, data, []).nearMiles).toEqual([]);
  });
  it('works against the real data for 2020', () => {
    const p = positionPrice(90000, 2020, 3000);
    expect(p.points.length).toBe(auctionResults.filter((x) => x.year === 2020 && !x.outlier && x.outcome === 'sold' && x.price !== null).length);
    expect(p.below + p.above + p.same).toBe(p.points.length);
    expect(p.stats.length).toBeGreaterThan(0);
  });
});

describe('buyer ticks storage and backup v10', () => {
  it('normalizes, saves and loads', () => {
    expect(normBuyer(null)).toBeNull();
    expect(normBuyer({ checked: ['recall:x', 'recall:x', 5, 'bad id!'] })).toEqual({ checked: ['recall:x'] });
    const s = toggleCheck(toggleCheck({ checked: [] }, 'paint:a', true), 'paint:b', true);
    expect(toggleCheck(s, 'paint:a', false).checked).toEqual(['paint:b']);
    expect(saveBuyer(s)).toBe(true);
    expect(JSON.parse(store.get(BUYER_KEY)!)).toEqual({ checked: ['paint:a', 'paint:b'] });
    expect(loadBuyer()).toEqual(s);
    store.set(BUYER_KEY, '{bad');
    expect(loadBuyer()).toEqual({ checked: [] });
  });
  it('schema 10 round-trips buyer, migrates v9, rejects malformed, restores, resets', () => {
    expect(SCHEMA_VERSION).toBe(10);
    expect(migrate({ schema: 9 })).toMatchObject({ schema: 10, buyer: { checked: [] } });
    const b = makeBackup(EMPTY_GARAGE, [], [], [], [], undefined, undefined, undefined, { buyer: { checked: ['svc:w-pt'] } });
    const r = validateBackup(JSON.parse(JSON.stringify(b)));
    expect(r.ok && r.data.buyer).toEqual({ checked: ['svc:w-pt'] });
    expect(validateBackup({ ...b, buyer: 'x' }).ok).toBe(false);
    const v9 = { ...b, schema: 9 } as Record<string, unknown>; delete v9.buyer;
    const m = validateBackup(v9);
    expect(m.ok && m.migratedFrom).toBe(9);
    expect(m.ok && m.data.buyer).toEqual({ checked: [] });
    if (r.ok) { expect(restoreBackup(r.data)).toBe(true); expect(loadBuyer().checked).toEqual(['svc:w-pt']); }
    expect(ALL_KEYS).toContain(BUYER_KEY);
  });
});

describe('Buyer page wiring, i18n and render', () => {
  it('is in the menu and search', () => {
    expect(NAV.some((n) => n.to === '/buy' && n.key === 'nav.buy')).toBe(true);
    expect(search('buyer pre-purchase').some((h) => h.route === '/buy')).toBe(true);
  });
  it('every buy key exists in Spanish', () => {
    for (const k of Object.keys(en).filter((k) => /^buy\./.test(k) || ['nav.buy', 'help.tool.buy'].includes(k))) expect(es[k as keyof typeof es], k).toBeTruthy();
  });
  it('renders in both languages with labelled controls, sources and badges', () => {
    store.set(BUYER_KEY, JSON.stringify({ checked: ['svc:w-pt'] }));
    const h = wrap(<Buy />);
    expect(h).toContain('<h1>Buyer&#x27;s Guide</h1>');
    expect(h).toContain('Pre-purchase checklist');
    expect(h).toContain('static.nhtsa.gov');
    expect(h).toContain('badge-confirmed');
    expect(h).toMatch(/1 of \d+ checked/);
    expect(h).not.toContain('style=');
    const e = wrap(<Buy />, 'es');
    expect(e).toContain('Guía del comprador');
    expect(e).toContain('Lista de inspección previa a la compra');
  });
});
