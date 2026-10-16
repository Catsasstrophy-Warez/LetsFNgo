import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import type { Units } from '../src/lib/units';

const store = new Map<string, string>();
beforeAll(() => {
  vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
  const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
  store.set('gt500.drag.v1', JSON.stringify([
    { id: 'a', date: '2026-03-01', track: 'Texas Motorplex', rt: 0.5, sixty: 1.7, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: 11.2, quarterMph: 128, da: 2000, weather: w, mods: [], notes: '' },
    { id: 'g', date: '2026-04-01', track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null, weather: w, mods: [], notes: 'GPS estimate', gps: { kind: '0-60', seconds: 3.61, trapMph: null, accuracyM: 2.5 } },
  ]));
  store.set('gt500.garage.v1', JSON.stringify({ year: '2020', mods: [{ id: 'm', date: '2025-06-01', title: 'Tune', notes: '', cost: '900' }], service: [{ id: 's', date: '2025-01-01', title: 'Oil change', notes: '', cost: '150' }] }));
  store.set('gt500.fuel.v1', JSON.stringify([{ id: 'f', date: '2026-01-05', odometer: 1000, gallons: 10, price: 4.5, fuel: '93', blend: null, full: true, notes: '' }]));
  store.set('gt500.plans.v1', JSON.stringify([{ id: 'p', name: 'Big', modIds: ['vmp', 'hpj'], created: '' }]));
});
afterAll(() => vi.unstubAllGlobals());

async function render(name: string, units: Units = 'imperial') {
  const { PAGES } = await import('../src/App');
  const { default: Page } = await PAGES[name as keyof typeof PAGES]();
  return renderToString(
    <SettingsContext.Provider value={{ settings: { units, theme: 'dark' }, setSettings: () => undefined }}>
      <MemoryRouter><Page /></MemoryRouter>
    </SettingsContext.Provider>,
  ).replace(/<!-- -->/g, '');
}

describe('round-5 pages render', () => {
  it('Timer: big buttons, laps, save to Track', async () => {
    const h = await render('Timer');
    for (const t of ['Session Timer', '0:00.00', 'big-btn', '>Start<', '>Lap<', 'Save to Track log', 'No laps yet']) expect(h).toContain(t);
  });
  it('GPS meter: approximate label, never armed on render, run types', async () => {
    const h = await render('GpsMeter');
    for (const t of ['GPS Performance Meter', 'approximate', '0–60 mph', '60–130 mph', '¼ mile', 'Arm GPS', 'closed course', 'GPS estimate']) expect(h).toContain(t);
    expect(h).not.toContain('Armed<');
  });
  it('Timeline: yearly summary and entries from every log', async () => {
    const h = await render('Timeline');
    for (const t of ['Ownership Timeline', 'Yearly summary', '2026', '2025', 'Oil change', 'Tune', 'Texas Motorplex', 'GPS estimate', '$45.00', '$900.00']) expect(h).toContain(t);
    expect(await render('Timeline', 'metric')).toContain(' L');
  });
  it('Year & Rival Compare: years, colors, prices and head-to-head', async () => {
    const h = await render('YearCompare');
    for (const t of ['Year &amp; Rival Compare', 'Colors by year', 'Packages by year', 'Prices by year', 'Grabber Lime', 'Head-to-head', 'Not sourced', 'badge-confirmed']) expect(h).toContain(t);
  });
  it('Welcome: 3 steps and skip', async () => {
    const h = await render('Welcome');
    for (const t of ['Step 1 of 3', 'Model year', 'Skip intro', 'VIN (optional)', 'Units']) expect(h).toContain(t);
  });
  it('Planner shows sourced compatibility warnings', async () => {
    const h = await render('Planner');
    for (const t of ['Compatibility &amp; order of operations', 'DCT clutch rating', 'More than one supercharger', 'race fuel', 'Suggested order']) expect(h).toContain(t);
  });
  it('Drag shows GPS estimates apart from strip stats', async () => {
    const h = await render('Drag');
    expect(h).toContain('GPS estimate'); expect(h).toContain('3.61 s'); expect(h).toContain('not included in strip stats');
    expect(h).toContain('11.200');
  });
  it('Settings can re-run the intro', async () => {
    expect(await render('Settings')).toContain('Run intro again');
  });
});
