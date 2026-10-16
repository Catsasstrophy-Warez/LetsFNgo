import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { SettingsContext } from '../src/components/SettingsContext';
import { LineChart } from '../src/components/LineChart';
import { ErrorBoundary } from '../src/components/ErrorBoundary';
import type { Units } from '../src/lib/units';

const store = new Map<string, string>();
beforeAll(() => {
  vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
  const w = { tempF: 80, pressureInHg: 29.9, humidity: 40, elevationFt: 500, pressureIsStation: false };
  const slip = (id: string, date: string, quarterEt: number, quarterMph: number) => ({ id, date, track: 'Texas Motorplex', rt: 0.5, sixty: 1.7, threeThirty: 4.5, eighthEt: 7.1, eighthMph: 105, quarterEt, quarterMph, da: 2000, weather: w, mods: ['Tune'], notes: '' });
  store.set('gt500.drag.v1', JSON.stringify([slip('a', '2026-03-01', 11.2, 128), slip('b', '2026-04-01', 10.9, 131)]));
  const fill = (id: string, odometer: number, gallons: number, full = true) => ({ id, date: `2026-0${id}-01`, odometer, gallons, price: 4.5, fuel: '93', blend: null, full, notes: '' });
  store.set('gt500.fuel.v1', JSON.stringify([fill('1', 1000, 12), fill('2', 1180, 13), fill('3', 1350, 12)]));
  store.set('gt500.garage.v1', JSON.stringify({ nickname: 'Snake', year: '2020', color: 'race-red', odometer: '1350', vin: '', mods: [{ id: 'm', date: '2026-01-01', title: 'Tune', notes: '', cost: '900' }], service: [{ id: 's', date: '2026-01-01', title: 'Oil', notes: '', cost: '150' }] }));
  store.set('gt500.track.v1', JSON.stringify([
    { id: 't1', date: '2026-01-01', track: 'Laguna Seca', laps: '1:40.0\n1:39.5', pressures: {} },
    { id: 't2', date: '2026-02-01', track: 'Laguna Seca', laps: '1:38.2', pressures: {} },
  ]));
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

describe('new pages render with data', () => {
  it('Drag: stats, slips, chart, DA-corrected estimate, stock passes', async () => {
    const h = await render('Drag');
    expect(h).toContain('10.900'); expect(h).toContain('131.0 mph'); expect(h).toContain('DA-corrected');
    expect(h).toContain('estimate'); expect(h).toContain('<svg'); expect(h).toContain('10.61 s');
    expect(h).toContain('Density altitude calculator');
    expect(await render('Drag', 'metric')).toContain('km/h');
  });
  it('Fuel: mpg, cost charts and ownership cost', async () => {
    const h = await render('Fuel');
    expect(h).toContain('Ownership cost'); expect(h).toContain('$900.00'); expect(h).toContain('$150.00');
    expect(h).toContain('Fuel economy (mpg)');
    expect((h.match(/<svg/g) ?? []).length).toBeGreaterThanOrEqual(2);
    expect(await render('Fuel', 'metric')).toContain('L/100 km');
  });
  it('Garage and Track show trends; Garage links to Settings data', async () => {
    const g = await render('Garage');
    expect(g).toContain('Best lap trend'); expect(g).toContain('ET trend'); expect(g).toContain('/settings#data');
    expect(g).not.toContain('Export JSON');
    expect(await render('Track')).toContain('Lap-time trend');
  });
  it('Settings has units, theme and data management', async () => {
    const h = await render('Settings');
    for (const t of ['Imperial', 'Metric', 'Match device', 'Export JSON', 'Import JSON', 'Reset all data', 'schema v2']) expect(h).toContain(t);
  });
  it('Visualizer, print sheet and quiz', async () => {
    const v = await render('Visualizer');
    expect(v).toContain('Paint code'); expect(v).toContain('Rarity rank'); expect(v).toContain('Show racing stripes');
    const p = await render('PrintSheet', 'metric');
    expect(p).toContain('Snake'); expect(p).toContain('Print / save as PDF'); expect(p).toContain('2,173 km'); expect(p).toContain('N·m');
    const q = await render('Quiz');
    expect(q).toContain('Question 1 of 10');
  });
  it('Specs, Gearing and Tools convert to metric', async () => {
    expect(await render('Specs', 'metric')).toContain('847');
    const g = await render('Gearing', 'metric');
    expect(g).toContain('km/h'); expect(g).toContain('dealer/classified listing');
    expect(await render('PerfTools', 'metric')).toContain('kg');
  });
  it('Ownership groups recalls by GT500 applicability', async () => {
    const h = await render('Ownership');
    for (const t of ['applies to the GT500', 'likely applies (VIN check)', 'depends on VIN', 'not applicable to the GT500', 'CSP 21B26', 'SSM 49440']) expect(h).toContain(t);
  });
});

describe('components', () => {
  it('LineChart is accessible and handles too few points', () => {
    const h = renderToString(<LineChart title="T" points={[{ label: 'a', value: 1 }, { label: 'b', value: 2 }]} format={(v) => v.toFixed(1)} unit="s" />);
    expect(h).toContain('role="img"'); expect(h).toContain('<desc'); expect(h).toContain('Data table');
    expect(renderToString(<LineChart title="T" points={[]} format={String} unit="s" />)).toContain('at least two');
  });
  it('ErrorBoundary catches errors', () => {
    expect(ErrorBoundary.getDerivedStateFromError(new Error('x'))).toEqual({ error: new Error('x') });
  });
});
