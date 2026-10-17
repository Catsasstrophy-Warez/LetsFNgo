import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter, Route, Routes } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import type { Settings } from '../src/lib/units';
import { en, LANGS, missingKeys, normLang, translate } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { normalizeSettings } from '../src/lib/units';
import { copyText, filterParts } from '../src/lib/parts';
import { partNumbers, partsForReminder } from '../src/data/parts';
import { guides, weakestStep } from '../src/data/guides';
import { maintenance } from '../src/data/maintenance';
import { modStages } from '../src/data/mods';
import { DEFAULT_REMINDERS } from '../src/lib/garage';
import { checklistKey, loadChecks, saveChecks } from '../src/lib/checklist';
import { csvCell, factRows, toCsv, toJson } from '../src/lib/factExport';
import { createPrefetcher, routeOf } from '../src/lib/prefetch';
import { isNativeApp, shouldRegisterSW } from '../src/lib/platform';
import { costPerHp } from '../src/lib/roi';
import { makeBackup, validateBackup } from '../src/lib/backup';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { search } from '../src/lib/search';
import { NAV } from '../src/App';

const mem = () => { const m = new Map<string, string>(); return { m, getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => { m.set(k, v); }, removeItem: (k: string) => { m.delete(k); } }; };

describe('i18n', () => {
  it('English is complete; Spanish covers navigation and Settings', () => {
    expect(missingKeys('en')).toEqual([]);
    const required = (Object.keys(en) as (keyof typeof en)[]).filter((k) => k.startsWith('nav.') || k.startsWith('settings.') || k.startsWith('chrome.'));
    expect(required.filter((k) => !es[k])).toEqual([]);
    for (const n of NAV) expect(es[n.key]).toBeTruthy();
    expect(translate('es', 'nav.settings')).toBe('Ajustes');
    expect(LANGS.map(([l]) => l)).toEqual(['en', 'es']);
  });
  it('falls back to English, fills placeholders, normalizes language', () => {
    expect(translate('en', 'nav.home', { x: 1 })).toBe('Home');
    expect(normLang('fr')).toBe('en');
    expect(normalizeSettings({ lang: 'es' }).lang).toBe('es');
    expect(normalizeSettings({ lang: 42 }).lang).toBe('en');
  });
  it('language survives a backup round-trip (no schema bump: it lives in settings)', () => {
    const b = makeBackup(EMPTY_GARAGE, [], [], [], [], { units: 'metric', theme: 'dark', lang: 'es' });
    const r = validateBackup(JSON.parse(JSON.stringify(b)));
    expect(r.ok && r.data.settings.lang).toBe('es');
  });
});

describe('parts catalog', () => {
  it('only sourced numbers; every link resolves', () => {
    const mIds = new Set(maintenance.map((m) => m.id));
    const rIds = new Set(DEFAULT_REMINDERS.map((r) => r.id));
    for (const p of partNumbers) {
      expect(p.source).toMatch(/^https:\/\//);
      p.maintenanceIds.forEach((id) => expect(mIds.has(id), id).toBe(true));
      p.reminderIds.forEach((id) => expect(rIds.has(id), id).toBe(true));
    }
    for (const n of ['FL-2087', 'SP-581', 'XT-14-L', 'VC-13DL-G', 'M-6766-A52', 'M-16601-MCF']) expect(partNumbers.some((p) => p.number === n)).toBe(true);
    // Each seeded Motorcraft number appears in a sourced maintenance fact (FL-500-S is a round-6 unverified extra).
    for (const p of partNumbers.filter((x) => x.maintenanceIds.length)) expect(maintenance.some((m) => JSON.stringify(m).includes(p.number))).toBe(true);
    const fl500 = partNumbers.find((p) => p.number === 'FL-500-S')!;
    expect(fl500.confidence).toBe('unverified');
    expect(fl500.note).toMatch(/not confirmed for the GT500/);
  });
  it('search is dash-insensitive and reminders map to parts', () => {
    expect(filterParts('fl2087').map((p) => p.number)).toEqual(['FL-2087']);
    expect(filterParts('coolant').length).toBeGreaterThan(0);
    expect(filterParts('zzz')).toEqual([]);
    expect(filterParts('').length).toBe(partNumbers.length);
    expect(partsForReminder('r-oil').map((p) => p.number)).toContain('FL-2087');
    expect(partsForReminder('r-dct').some((p) => p.kind === 'avoid')).toBe(true);
    expect(search('FL-2087').some((h) => h.route === '/parts')).toBe(true);
  });
  it('copyText uses the Clipboard API and reports failure', async () => {
    const writeText = vi.fn(async () => undefined);
    expect(await copyText('SP-581', { clipboard: { writeText } } as never)).toBe(true);
    expect(writeText).toHaveBeenCalledWith('SP-581');
    expect(await copyText('x', { clipboard: { writeText: async () => { throw new Error('no'); } } } as never)).toBe(false);
  });
});

describe('guides', () => {
  it('ready guides are fully sourced; confidence never above the weakest step; planned slots are empty', () => {
    const pIds = new Set(partNumbers.map((p) => p.id));
    const RANK = { confirmed: 2, reported: 1, unverified: 0 };
    for (const g of guides) {
      g.partIds.forEach((id) => expect(pIds.has(id), id).toBe(true));
      if (g.status === 'planned') { expect(g.steps).toEqual([]); continue; }
      expect(g.steps.length).toBeGreaterThan(0);
      g.steps.forEach((s) => expect(s.source).toMatch(/^https:\/\//));
      expect(RANK[g.confidence]).toBeLessThanOrEqual(RANK[weakestStep(g)]);
      g.steps.filter((s) => s.factId).forEach((s) => expect(maintenance.some((m) => m.id === s.factId), s.factId).toBe(true));
    }
  });
  it('break-in is not presented as 2020 guidance', () => {
    const b = guides.find((g) => g.id === 'break-in')!;
    expect(b.status).toBe('planned');
    expect(b.steps).toEqual([]);
    expect(JSON.stringify(guides)).not.toMatch(/100 mi before extended WOT/);
  });
  it('checklists persist per session and survive corrupt data', () => {
    const s = mem();
    saveChecks('g', [true, false, true], s);
    expect(loadChecks('g', 3, s)).toEqual([true, false, true]);
    expect(loadChecks('g', 2, s)).toEqual([true, false]);
    s.m.set(checklistKey('g'), '{bad');
    expect(loadChecks('g', 2, s)).toEqual([false, false]);
    expect(loadChecks('g', 2, null)).toEqual([false, false]);
  });
});

describe('round-6 mods', () => {
  it('JLT is the one low-confidence cost/hp example; packs have prices and no gain; combo has no per-part gain', () => {
    const ok = costPerHp(modStages).filter((r) => r.ok);
    const jlt = ok.find((r) => r.mod.id === 'jlt-intake');
    expect(jlt && jlt.ok && jlt.perHpMin).toBeCloseTo(399 / 25, 6);
    expect(jlt?.mod.confidence).toBe('unverified');
    expect(jlt?.mod.gain?.basis).toMatch(/manufacturer claim, no dyno sheet/i);
    for (const id of ['vmp-stage2', 'vmp-predator-eo']) { const m = modStages.find((x) => x.id === id)!; expect(m.cost).toBeTruthy(); expect(m.gain).toBeUndefined(); expect(m.confidence).toBe('reported'); }
    const fm = modStages.find((m) => m.id === 'fm-boltons')!;
    expect(fm.gain).toBeUndefined();
    expect(fm.result).toContain('674 → 828 rwhp');
    expect(JSON.stringify(modStages)).not.toMatch(/odin/i);
  });
});

describe('fact export', () => {
  it('flattens every sourced fact with source and confidence', () => {
    const rows = factRows();
    expect(rows.length).toBeGreaterThan(300);
    expect(rows.every((r) => r.source && r.collection)).toBe(true);
    expect(rows.some((r) => r.collection === 'maintenance' && r.path.includes('conflicts[0]'))).toBe(true);
    expect(rows.some((r) => r.collection === 'guides' && r.path.includes('steps[0]'))).toBe(true);
    const fl = rows.find((r) => r.id === 'fl-2087' && r.path === 'fl-2087')!;
    expect(fl.label).toBe('FL-2087');
    expect(fl.confidence).toBe('reported');
  });
  it('CSV is quoted and safe against formula injection; JSON parses', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`);
    expect(csvCell('-2.25')).toBe("'-2.25");
    const rows = factRows().slice(0, 5);
    const csv = toCsv(rows);
    expect(csv.split('\r\n')[0]).toBe('collection,id,path,label,value,source,originalUrl,confidence,note');
    expect(JSON.parse(toJson(rows, 'x')).count).toBe(5);
  });
});

describe('prefetch & platform', () => {
  it('maps hrefs to routes and loads each chunk once', async () => {
    expect(routeOf('#/specs')).toBe('/specs');
    expect(routeOf('./#/guides/dct-fluid?x=1')).toBe('/guides');
    expect(routeOf('#/')).toBe('/');
    expect(routeOf('https://example.com')).toBeNull();
    expect(routeOf(null)).toBeNull();
    const f = vi.fn(async () => 1);
    const p = createPrefetcher({ '/specs': f });
    expect(p('#/specs')).toBe(true);
    expect(p('#/specs')).toBe(false);
    expect(p('#/nope')).toBe(false);
    expect(f).toHaveBeenCalledTimes(1);
    const bad = vi.fn(async () => { throw new Error('offline'); });
    const p2 = createPrefetcher({ '/x': bad });
    p2('#/x'); await new Promise((r) => setTimeout(r, 0));
    expect(p2('#/x')).toBe(true); // retried after failure
  });
  it('detects the Capacitor wrapper and skips the service worker there', () => {
    expect(isNativeApp({ Capacitor: { isNativePlatform: () => true } })).toBe(true);
    expect(isNativeApp({})).toBe(false);
    expect(isNativeApp(undefined)).toBe(false);
    expect(shouldRegisterSW({}, { serviceWorker: {} })).toBe(true);
    expect(shouldRegisterSW({ Capacitor: { isNativePlatform: () => true } }, { serviceWorker: {} })).toBe(false);
    expect(shouldRegisterSW({}, {})).toBe(false);
  });
});

describe('round-7 pages render', () => {
  const ss = mem();
  beforeAll(() => { vi.stubGlobal('sessionStorage', ss); vi.stubGlobal('localStorage', mem()); });
  afterAll(() => vi.unstubAllGlobals());
  async function render(name: string, path = '/', route = '/', settings: Partial<Settings> = {}) {
    const { PAGES } = await import('../src/App');
    const { default: Page } = await PAGES[name as keyof typeof PAGES]();
    return renderToString(
      <SettingsContext.Provider value={{ settings: { units: 'imperial', theme: 'dark', lang: 'en', ...settings }, setSettings: () => undefined }}>
        <MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={<Page />} /></Routes></MemoryRouter>
      </SettingsContext.Provider>,
    ).replace(/<!-- -->/g, '');
  }
  it('Parts: list, copy buttons, filter from ?q=, empty slots', async () => {
    const h = await render('Parts');
    for (const t of ['Parts &amp; Fluids', 'FL-2087', 'SP-581', 'XT-14-L', 'VC-13DL-G', 'Copy FL-2087', 'Do not use', 'Not sourced yet', 'badge-confirmed']) expect(h).toContain(t);
    const f = await render('Parts', '/parts?q=sp581', '/parts');
    expect(f).toContain('SP-581'); expect(f).not.toContain('Copy FL-2087');
  });
  it('Guides list and a guide with persisted ticks', async () => {
    const l = await render('Guides');
    for (const t of ['How-to Guides', 'Track-day maintenance', 'DCT fluid', 'Planned (not yet sourced)', 'Break-in']) expect(l).toContain(t);
    ss.setItem(checklistKey('track-service'), JSON.stringify([true, false]));
    const g = await render('Guide', '/guides/track-service', '/guides/:id');
    for (const t of ['Track-day maintenance', 'DOT 4 LV', '1 of 4 done', 'No tool list is sourced', 'FL-2087', 'Warning:']) expect(g).toContain(t);
    expect(g).toMatch(/checked=""/);
    expect(await render('Guide', '/guides/nope', '/guides/:id')).toContain('Guide not found');
    expect(await render('Guide', '/guides/break-in', '/guides/:id')).toContain('planned slot');
  });
  it('Sources: download buttons; Settings: language picker, Spanish strings', async () => {
    const s = await render('Sources');
    for (const t of ['Download CSV', 'Download JSON', 'sourced facts']) expect(s).toContain(t);
    const en1 = await render('Settings');
    expect(en1).toContain('Language'); expect(en1).toContain('Español');
    const es1 = await render('Settings', '/', '/', { lang: 'es' });
    for (const t of ['Ajustes', 'Unidades', 'Idioma', 'Igual que el dispositivo']) expect(es1).toContain(t);
  });
});
