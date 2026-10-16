import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter, Route, Routes } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import type { Units } from '../src/lib/units';
import { encodeShare } from '../src/lib/share';

const store = new Map<string, string>();
beforeAll(() => {
  vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
  const w = { tempF: 80, pressureInHg: 29.5, humidity: 30, elevationFt: 0, pressureIsStation: true };
  store.set('gt500.dyno.v1', JSON.stringify([
    { id: 'd1', date: '2026-02-01', shop: 'Local', whp: 680, wtq: 590, dynoType: 'dynojet', correction: 'sae', weather: w, mods: ['Tune'], curve: [{ rpm: 3000, hp: 300, tq: 520 }, { rpm: 7000, hp: 680, tq: 510 }], notes: '' },
    { id: 'bad', whp: 'x' },
  ]));
  store.set('gt500.plans.v1', JSON.stringify([{ id: 'p', name: 'Big', modIds: ['tune', 'whipple'], created: '' }]));
  store.set('gt500.home.v1', JSON.stringify({ order: ['tools', 'garage', 'stats', 'legend', 'reference'], hidden: ['legend'] }));
});
afterAll(() => vi.unstubAllGlobals());

async function render(name: string, units: Units = 'imperial', path = '/', route = '/') {
  const { PAGES } = await import('../src/App');
  const { default: Page } = name === 'Home' ? await import('../src/pages/Home') : await PAGES[name as keyof typeof PAGES]();
  return renderToString(
    <SettingsContext.Provider value={{ settings: { units, theme: 'dark' }, setSettings: () => undefined }}>
      <MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={<Page />} /></Routes></MemoryRouter>
    </SettingsContext.Provider>,
  ).replace(/<!-- -->/g, '');
}

describe('round-6 pages render', () => {
  it('Dyno: form, converter, chart overlay, baselines; bad rows dropped', async () => {
    const h = await render('Dyno');
    for (const t of ['Dyno Log', 'SAE J1349', 'STD (SAE J607)', 'Mustang (load-bearing)', 'SAE ↔ STD converter', 'Local', '680 whp', 'Sourced stock baselines', '708 whp', 'badge-unverified', 'Mods: Tune', 'Data table']) expect(h).toContain(t);
    expect(await render('Dyno', 'metric')).toContain('N·m');
  });
  it('Tires: comparison, speedo and gearing tables', async () => {
    const h = await render('Tires');
    for (const t of ['Tire &amp; Wheel Calculator', '315/30R20', 'Revs per mile', 'Effective final drive', 'reads low', 'Gearing effect', 'More than 3%']) expect(h).toContain(t);
    expect(await render('Tires', 'metric')).toContain('Revs per km');
  });
  it('Share: plan view, car view and damaged link', async () => {
    const plan = encodeShare({ v: 1, k: 'plan', name: 'Weekend', modIds: ['whipple'] })!;
    const h = await render('Share', 'imperial', `/share/${plan}`, '/share/:data');
    for (const t of ['Shared build plan', 'Weekend', '$8,100–$8,850', 'Import to my Build Planner', 'Read-only']) expect(h).toContain(t);
    const car = encodeShare({ v: 1, k: 'car', year: '2021', color: 'race-red', nickname: '<b>x</b>', mods: ['Tune'] })!;
    const c = await render('Share', 'imperial', `/share/${car}`, '/share/:data');
    for (const t of ['Shared car', '&lt;b&gt;x&lt;/b&gt;', '2021', 'Import to my Garage', 'never include a VIN']) expect(c).toContain(t);
    expect(await render('Share', 'imperial', '/share/%%%', '/share/:data')).toContain('damaged');
  });
  it('Planner: cost per hp with insufficient data and share link', async () => {
    const h = await render('Planner');
    for (const t of ['Cost per horsepower', 'insufficient data', 'no sourced price', 'no sourced gain', 'Share plan as link']) expect(h).toContain(t);
  });
  it('Home follows the saved layout', async () => {
    const h = await render('Home');
    expect(h.indexOf('<h2>Tools</h2>')).toBeLessThan(h.indexOf('My Garage'));
    expect(h).not.toContain('Confidence:</strong>');
    expect(h).toContain('Customize Home');
  });
  it('Settings has the notifications toggle (unsupported fallback in SSR)', async () => {
    const h = await render('Settings');
    for (const t of ['Maintenance notifications', 'does not support notifications', 'schema v4']) expect(h).toContain(t);
  });
  it('Year compare tables carry stacked-card labels', async () => {
    const h = await render('YearCompare');
    expect(h).toContain('tbl diff stack'); expect(h).toContain('data-label="2021"'); expect(h).toContain('data-label="Ref."');
  });
});
