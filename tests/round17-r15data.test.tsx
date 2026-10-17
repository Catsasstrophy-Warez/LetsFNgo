import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { CarContext } from '../src/components/CarContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { INSURANCE_POINTS, SCHEDULE, SOURCED_SERVICE_PRICES, estimate, servicePricing, sourcedQuarts, sourcedServicePrices } from '../src/lib/cost';
import { emptyInputs } from '../src/lib/costStore';
import { recalls } from '../src/data/recalls';
import { partNumbers } from '../src/data/parts';
import { maintenance } from '../src/data/maintenance';
import { auctionResults } from '../src/data/auctions';
import { milestones } from '../src/data/history';
import Cost from '../src/pages/Cost';
import type { MaintenanceItem, PartNumber } from '../src/data/types';

const oilCap = (value: string | number): MaintenanceItem => ({ id: 'oil-cap', group: 'Fluids', item: 'Engine oil capacity', value, unit: 'qt', source: 'https://example.com/cap', confidence: 'reported' });
const byId = (id: string) => partNumbers.find((p) => p.id === id)!;

describe('round 15 data', () => {
  it('adds TSB 24-2327 once and links it to the DCT cooler-line vendor claim', () => {
    const t = recalls.filter((r) => r.campaign === 'TSB 24-2327');
    expect(t).toHaveLength(1);
    expect(t[0]).toMatchObject({ id: 'tsb-24-2327', kind: 'tsb', confidence: 'confirmed', appliesToGT500: 'yes', source: 'https://static.nhtsa.gov/odi/tsbs/2024/MC-11009440-0001.pdf' });
    expect(t[0].summary).toMatch(/KR3Z-7R081-C/);
    expect(t[0].note).toMatch(/dct-lines/);
    expect(recalls.find((r) => r.id === 'dct-lines')!.note).toMatch(/Corroborated by Ford TSB 24-2327/);
  });
  it('part prices: exactly the oil and filter, with date seen and conflicts', () => {
    expect(partNumbers.filter((p) => p.price).map((p) => p.id)).toEqual(['fl-2087', 'xo-5w50-qgt']);
    expect(byId('xo-5w50-qgt').price).toMatchObject({ value: 14.94, per: 'quart', dateSeen: '2026-10-17', confidence: 'reported' });
    expect(byId('xo-5w50-qgt').price!.conflicts!.map((c) => c.value)).toEqual([12.21, 14.18, 12.67, 16.33, 22.76, 25.95]);
    expect(byId('fl-2087').price).toMatchObject({ value: 22.79, per: 'each', confidence: 'unverified' });
  });
  it('insurance points are exactly the two sourced, unverified data points', () => {
    expect(INSURANCE_POINTS.map((m) => [m.id, m.value, m.confidence])).toEqual([['ins-motortrend', 2488, 'unverified'], ['ins-autoblog', 1800, 'unverified']]);
    expect(emptyInputs().insurance).toBeNull();
    const e = estimate({ ...emptyInputs(), annualMiles: 5000, years: 1 }, null);
    expect(e.lines.find((l) => l.id === 'insurance')).toMatchObject({ perYear: null, priceOrigin: null });
  });
  it('one Mecum Dallas sale and the Hot List milestone', () => {
    expect(auctionResults.filter((r) => r.price === 118250)).toHaveLength(1);
    expect(auctionResults.find((r) => r.id === 'mecum-dallas-2022-09')).toMatchObject({ confidence: 'unverified', outcome: 'sold', year: 2020 });
    expect(milestones.filter((m) => /Hot List/.test(m.title))).toHaveLength(1);
  });
});

describe('priced services', () => {
  it('the real data leaves the oil change unpriced: capacity is a conflicting range', () => {
    expect(sourcedQuarts(maintenance.find((m) => m.id === 'oil-cap'))).toBeNull();
    const p = servicePricing('r-oil');
    expect(p.price).toBeNull();
    expect(p.parts.map((x) => [x.part.id, x.reason])).toEqual([['fl-2087', 'priced'], ['xo-5w50-qgt', 'no-capacity']]);
    expect(SOURCED_SERVICE_PRICES).toEqual({});
  });
  it('oil change is priced only when the capacity and both parts are sourced', () => {
    const facts = [oilCap('10')];
    const r = servicePricing('r-oil', partNumbers, facts);
    expect(r.price).toMatchObject({ value: 22.79 + 14.94 * 10, confidence: 'unverified' });
    expect(sourcedServicePrices(SCHEDULE, partNumbers, facts)).toHaveProperty('r-oil');
    // filter price missing → unpriced
    const noFilter: PartNumber[] = partNumbers.map((p) => (p.id === 'fl-2087' ? { ...p, price: undefined } : p));
    expect(servicePricing('r-oil', noFilter, facts).price).toBeNull();
    // oil price missing → unpriced
    const noOil: PartNumber[] = partNumbers.map((p) => (p.id === 'xo-5w50-qgt' ? { ...p, price: undefined } : p));
    expect(servicePricing('r-oil', noOil, facts).price).toBeNull();
    // range capacity → unpriced
    expect(servicePricing('r-oil', partNumbers, [oilCap('10–11.5')]).price).toBeNull();
  });
  it('services with no parts or an unpriced part stay unpriced, and the total reads at least', () => {
    for (const id of ['r-cabin', 'r-air', 'r-plugs', 'r-dct', 'r-coolant']) expect(servicePricing(id).price, id).toBeNull();
    const e = estimate({ ...emptyInputs(), annualMiles: 10000, years: 1 }, null);
    expect(e.atLeast).toBe(true);
  });
  it('the Cost page shows reference prices and insurance points without filling inputs', () => {
    const html = renderToString(
      <SettingsContext.Provider value={{ settings: DEFAULT_SETTINGS, setSettings: () => undefined }}>
        <CarContext.Provider value={{ active: 'car1', cars: [], version: 0, switchCar: () => undefined, refresh: () => undefined }}>
          <MemoryRouter><Cost /></MemoryRouter>
        </CarContext.Provider>
      </SettingsContext.Provider>,
    );
    expect(html).toMatch(/Insurance reference data points/);
    expect(html).toMatch(/\$2,488/);
  });
});
