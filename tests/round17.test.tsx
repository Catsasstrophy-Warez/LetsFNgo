import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { CarContext } from '../src/components/CarContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { SCHEDULE, SOURCED_SERVICE_PRICES, epaCombined, estimate, loggedCosts, timesDue, valuePoints } from '../src/lib/cost';
import { COST_KEY, emptyInputs, inputsFor, loadCost, normCost, saveCost, withInputs, type CostInputs } from '../src/lib/costStore';
import { ALL_KEYS, SCHEMA_VERSION, makeBackup, migrate, restoreBackup, validateBackup } from '../src/lib/backup';
import { KEYS, EMPTY_GARAGE } from '../src/lib/garage';
import { search } from '../src/lib/search';
import { NAV } from '../src/App';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { marketStats } from '../src/data/auctions';
import Cost from '../src/pages/Cost';
import type { AuctionResult, MarketStat } from '../src/data/types';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });
beforeEach(() => store.clear());

const wrap = (el: JSX.Element, lang: 'en' | 'es' = 'en', active = 'car1') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang }, setSettings: () => undefined }}>
    <CarContext.Provider value={{ active, cars: [], version: 0, switchCar: () => undefined, refresh: () => undefined }}>
      <MemoryRouter>{el}</MemoryRouter>
    </CarContext.Provider>
  </SettingsContext.Provider>,
);
const inputs = (o: Partial<CostInputs>): CostInputs => ({ ...emptyInputs(), ...o });

describe('calculations', () => {
  it('counts services by whichever interval comes first', () => {
    expect(timesDue({ everyMiles: 10000, everyMonths: 12 }, 3000, 5)).toBe(5); // yearly wins at low miles
    expect(timesDue({ everyMiles: 10000, everyMonths: 12 }, 25000, 2)).toBe(5); // miles win
    expect(timesDue({ everyMiles: null, everyMonths: 36 }, 5000, 3)).toBe(1);
    expect(timesDue({ everyMiles: 100000, everyMonths: null }, 5000, 3)).toBe(0);
  });
  it('needs annual miles and years; nothing is defaulted', () => {
    expect(estimate(emptyInputs(), null).ready).toBe(false);
    expect(emptyInputs()).toMatchObject({ insurance: null, fuelPrice: null, tireSet: null, purchasePrice: null });
  });
  it('totals priced lines per year, over the period and per mile', () => {
    const e = estimate(inputs({ annualMiles: 5000, years: 4, fuelPrice: 4, insurance: 2000, tireSet: 1600, tireLife: 10000, servicePrices: { 'r-oil': 150, 'r-brake': 120, 'r-cabin': 50, 'r-dct-top': 100, 'r-air': 60 } }), 14);
    expect(e.ready).toBe(true);
    const fuel = (5000 / 14) * 4, tires = (5000 / 10000) * 1600;
    const oil = (150 * 4) / 4, brake = (120 * 1) / 4, cabin = (50 * 1) / 4, top = (100 * 1) / 4;
    // 20,000 mi in 4 years: air filter (30k) is not due; neither are the 40k+ services.
    expect(e.notDue.map((s) => s.id)).toEqual(expect.arrayContaining(['r-air', 'r-dct', 'r-fuel', 'r-plugs', 'r-diff']));
    expect(e.perYear).toBeCloseTo(fuel + tires + 2000 + oil + brake + cabin + top, 6);
    expect(e.total).toBeCloseTo(e.perYear * 4, 6);
    expect(e.perMile).toBeCloseTo(e.perYear / 5000, 6);
    expect(e.unpriced).toBe(0);
    expect(e.atLeast).toBe(false);
  });
  it('uses the logged mpg, else the sourced EPA combined figure', () => {
    const epa = epaCombined();
    expect(epa?.value).toBe(14);
    expect(epa?.source).toMatch(/^https:\/\//);
    const own = estimate(inputs({ annualMiles: 6000, years: 1, fuelPrice: 5 }), 12).lines.find((l) => l.id === 'fuel')!;
    expect(own.perYear).toBeCloseTo(2500, 6);
    expect(own.mpg?.origin).toBe('user');
    expect(own.priceOrigin).toBe('user');
    const src = estimate(inputs({ annualMiles: 7000, years: 1, fuelPrice: 4 }), null).lines.find((l) => l.id === 'fuel')!;
    expect(src.perYear).toBeCloseTo(2000, 6);
    expect(src.mpg?.origin).toBe('sourced');
    expect(src.priceOrigin).toBe('mixed');
  });
});

describe('unpriced handling and labelling', () => {
  it('no service price is sourced; services without a typed cost are unpriced and the total reads at least', () => {
    expect(Object.keys(SOURCED_SERVICE_PRICES)).toHaveLength(0);
    for (const s of SCHEDULE) { expect(s.source).toMatch(/^https:\/\//); expect(s.confidence).toBe('reported'); }
    const e = estimate(inputs({ annualMiles: 10000, years: 3, insurance: 1500 }), null);
    const svc = e.lines.filter((l) => l.kind === 'service');
    expect(svc.length).toBeGreaterThan(0);
    for (const l of svc) { expect(l.perYear).toBeNull(); expect(l.priceOrigin).toBeNull(); }
    // fuel (no price) and tires (not entered) are unpriced too; insurance is the user's.
    expect(e.unpriced).toBe(svc.length + 2);
    expect(e.atLeast).toBe(true);
    expect(e.perYear).toBe(1500);
    expect(e.lines.find((l) => l.id === 'insurance')?.priceOrigin).toBe('user');
  });
  it('typed service costs are labelled as the user\'s; a sourced price would win and be labelled sourced', () => {
    const typed = estimate(inputs({ annualMiles: 10000, years: 1, servicePrices: { 'r-oil': 120 } }), null).lines.find((l) => l.id === 'r-oil')!;
    expect(typed).toMatchObject({ unitPrice: 120, perYear: 120, priceOrigin: 'user' });
    const src = estimate(inputs({ annualMiles: 10000, years: 1, servicePrices: { 'r-oil': 120 } }), null, SCHEDULE,
      { 'r-oil': { value: 90, source: 'https://example.com/oil', confidence: 'reported' } }).lines.find((l) => l.id === 'r-oil')!;
    expect(src).toMatchObject({ unitPrice: 90, priceOrigin: 'sourced', source: 'https://example.com/oil' });
  });
  it('value points are sourced data, compared with the user price, no forecast', () => {
    const stats: MarketStat[] = [{ id: 's', label: 'Median', year: 2021, kind: 'yearly-median', value: 90000, source: 'https://e.com/s', confidence: 'reported' },
      { id: 'e', label: 'Estimate', year: 2021, kind: 'estimate', value: 1, source: 'https://e.com/e', confidence: 'unverified' }];
    const base = { venue: null, mileage: null, cftp: null, heritage: null, description: '', source: 'https://e.com/a', confidence: 'reported' as const, date: '2025-01', year: 2021 as const, outcome: 'sold' as const };
    const results: AuctionResult[] = [{ ...base, id: 'a', price: 80000 }, { ...base, id: 'b', price: 100000 }, { ...base, id: 'c', price: 1, outlier: 'x' }, { ...base, id: 'd', price: 70000, outcome: 'offer' }];
    const pts = valuePoints(2021, 85000, stats, results);
    expect(pts).toHaveLength(2);
    expect(pts[0]).toMatchObject({ kind: 'stat', value: 90000, diff: 5000, source: 'https://e.com/s' });
    expect(pts[1]).toMatchObject({ kind: 'auctions', value: 90000, n: 2, diff: 5000 });
    expect(valuePoints(2021, null, stats, results)[0].diff).toBeNull();
    expect(valuePoints(null, 1)).toEqual([]);
    expect(valuePoints(2020, null).some((p) => p.id === marketStats[0].id)).toBe(true);
  });
  it('logged costs come from the car\'s own logs', () => {
    const fills = [{ id: 'a', date: '2026-01-01', odometer: 1000, gallons: 10, price: 4, fuel: '93' as const, blend: null, full: true, notes: '' },
      { id: 'b', date: '2026-02-01', odometer: 1140, gallons: 10, price: 5, fuel: '93' as const, blend: null, full: true, notes: '' }];
    const l = loggedCosts(fills, [{ id: 's', date: '2026-01-01', title: 'Oil', notes: '', cost: '$150' }], [{ id: 'm', date: '2026-01-01', title: 'Splitter', notes: '', cost: '1,990' }], 3);
    expect(l).toMatchObject({ fuel: 90, service: 150, mods: 1990, total: 2230, miles: 140, mpg: 14, trackSessions: 3, fills: 2 });
  });
});

describe('per-car storage', () => {
  it('stores inputs per car under a versioned key, normalizing bad data', () => {
    expect(COST_KEY).toBe('gt500.cost.v1');
    expect(loadCost()).toEqual({ cars: {} });
    let s = withInputs(loadCost(), 'car1', inputs({ annualMiles: 5000, insurance: 1800 }));
    s = withInputs(s, 'abc123', inputs({ annualMiles: 9000 }));
    expect(saveCost(s)).toBe(true);
    const back = loadCost();
    expect(inputsFor(back, 'car1')).toMatchObject({ annualMiles: 5000, insurance: 1800 });
    expect(inputsFor(back, 'abc123')).toMatchObject({ annualMiles: 9000, insurance: null });
    expect(inputsFor(back, 'nope')).toEqual(emptyInputs());
    store.set(COST_KEY, JSON.stringify({ cars: { car1: { annualMiles: -5, years: 'x', insurance: 1200, servicePrices: { 'r-oil': 99, '<b>': 5, 'r-air': -1 } }, '<x>': {} } }));
    expect(loadCost()).toEqual({ cars: { car1: { ...emptyInputs(), insurance: 1200, servicePrices: { 'r-oil': 99 } } } });
    expect(normCost([])).toBeNull();
    expect(ALL_KEYS).toContain(COST_KEY);
  });
});

describe('backup schema v11', () => {
  it('round-trips cost, migrates v10 with empty inputs, rejects malformed, restores', () => {
    expect(SCHEMA_VERSION).toBe(11);
    expect(migrate({ schema: 10 })).toMatchObject({ schema: 11, cost: { cars: {} } });
    expect(migrate({ schema: 1 })).toMatchObject({ schema: 11, cost: { cars: {} } });
    const cost = { cars: { car1: inputs({ annualMiles: 4000, servicePrices: { 'r-oil': 140 } }) } };
    const b = makeBackup({ ...EMPTY_GARAGE }, [], [], [], [], undefined, '2026-10-17T00:00:00Z', undefined, { cost });
    const v = validateBackup(JSON.parse(JSON.stringify(b)));
    expect(v.ok).toBe(true);
    if (v.ok) { expect(v.data.cost).toEqual(cost); expect(restoreBackup(v.data)).toBe(true); }
    expect(inputsFor(loadCost(), 'car1').servicePrices['r-oil']).toBe(140);
    const old = validateBackup({ ...JSON.parse(JSON.stringify(b)), schema: 10, cost: undefined });
    expect(old.ok && old.migratedFrom === 10 && old.data.cost).toEqual({ cars: {} });
    const bad = validateBackup({ ...JSON.parse(JSON.stringify(b)), cost: [] });
    expect(bad.ok).toBe(false);
  });
});

describe('i18n, nav, search, render', () => {
  it('every cost.* key has a Spanish translation', () => {
    const keys = Object.keys(en).filter((k) => k.startsWith('cost.') || k === 'nav.cost' || k === 'help.tool.cost');
    expect(keys.length).toBeGreaterThan(60);
    for (const k of keys) expect(es[k as keyof typeof es], k).toBeTruthy();
    for (const s of SCHEDULE) expect(en[`cost.svc.${s.id}` as keyof typeof en], s.id).toBeTruthy();
  });
  it('menu and search reach the page', () => {
    expect(NAV.some((n) => n.to === '/cost')).toBe(true);
    expect(search('cost of ownership').some((r) => r.route === '/cost')).toBe(true);
    expect(search('costo de propiedad').some((r) => r.route === '/cost')).toBe(true);
  });
  it('renders en and es with user vs sourced labels', () => {
    store.set(KEYS.cars, JSON.stringify({ active: 'car1', cars: [{ ...EMPTY_GARAGE, id: 'car1', year: '2020', nickname: 'Snake' }] }));
    const h0 = wrap(<Cost />);
    expect(h0).toContain('Cost of Ownership');
    expect(h0).toContain('Enter miles per year and years of ownership');
    store.set(COST_KEY, JSON.stringify({ cars: { car1: { annualMiles: 5000, years: 2, insurance: 2000, purchasePrice: 80000 } } }));
    const h = wrap(<Cost />);
    expect(h).toContain('Snake');
    expect(h).toContain('price not sourced');
    expect(h).toContain('at least $2,000');
    expect(h).toContain('Your number');
    expect(h).toContain('Sourced');
    expect(h).toContain('DriveIndex median');
    expect(h).toContain('not a forecast');
    const h2 = wrap(<Cost />, 'es');
    expect(h2).toContain('Costo de propiedad');
    expect(h2).toContain('precio sin fuente');
    expect(h2).toContain('al menos $2,000');
    expect(h2).toContain('Tu número');
    expect(h2).toContain('Con fuente');
  });
});
