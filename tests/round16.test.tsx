import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { packages } from '../src/data/packages';
import { prices } from '../src/data/pricing';
import { BUILD_KEY, baseLines, buildSticker, loadBuild, normBuild, optionPrice, optionsFor, saveBuild } from '../src/lib/buildSheet';
import { ALL_KEYS, SCHEMA_VERSION } from '../src/lib/backup';
import { search } from '../src/lib/search';
import { NAV } from '../src/App';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import BuildSheet from '../src/pages/BuildSheet';
import type { OptionPackage } from '../src/data/types';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });
beforeEach(() => store.clear());

const wrap = (el: JSX.Element, lang: 'en' | 'es' = 'en') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang }, setSettings: () => undefined }}><MemoryRouter>{el}</MemoryRouter></SettingsContext.Provider>,
);
const val = (id: string) => prices.find((p) => p.id === id)!.value!;
const pkg = (id: string) => packages.find((p) => p.id === id)!;

describe('sticker totals', () => {
  it('2020 base = base MSRP + destination + gas guzzler, all from sourced records', () => {
    const s = buildSticker(2020, []);
    expect(s.total).toBe(val('p20-base') + val('p20-dest') + val('p20-gg'));
    expect(s.unpriced).toBe(0);
    expect(s.atLeast).toBe(false);
    for (const l of s.lines) { expect(l.source).toMatch(/^https:\/\//); }
  });
  it('adds selected priced options', () => {
    const s = buildSticker(2020, ['cftp', 'recaro']);
    expect(s.total).toBe(val('p20-base') + val('p20-dest') + val('p20-gg') + pkg('cftp').price.value! + pkg('recaro').price.value!);
  });
});

describe('unpriced handling', () => {
  it('2021 has no sourced gas guzzler record: unpriced, excluded, total is "at least"', () => {
    const s = buildSticker(2021, []);
    const gg = s.lines.find((l) => l.kind === 'gas-guzzler')!;
    expect(gg.value).toBeNull();
    expect(s.total).toBe(val('p21-base') + val('p21-dest'));
    expect(s.atLeast).toBe(true);
    expect(s.unpriced).toBe(1);
  });
  it('null-priced option is excluded and counted', () => {
    const s = buildSticker(2020, ['extra-paint']);
    expect(s.lines.find((l) => l.id === 'extra-paint')!.value).toBeNull();
    expect(s.total).toBe(buildSticker(2020, []).total);
    expect(s.unpriced).toBe(1);
  });
  it('a price whose context names a year is not used for other years', () => {
    expect(optionPrice(pkg('handling'), 2020)).toBe(1500);
    expect(optionPrice(pkg('handling'), 2022)).toBeNull();
  });
});

describe('conflicts', () => {
  it('2022 uses the primary base MSRP record and lists the other as a conflict', () => {
    const msrp = baseLines(2022).find((l) => l.kind === 'msrp')!;
    expect(msrp.value).toBe(val('p22-base'));
    expect(msrp.conflicts.map((c) => c.value)).toEqual([val('p22-base-alt')]);
    expect(buildSticker(2022, []).total).toBe(val('p22-base') + val('p22-dest') + val('p22-gg'));
  });
  it('package price conflicts are shown but the primary value is totalled', () => {
    const l = buildSticker(2020, ['cftp']).lines.find((x) => x.id === 'cftp')!;
    expect(l.value).toBe(18500);
    expect(l.conflicts.length).toBeGreaterThan(0);
  });
});

describe('year filter and availability', () => {
  it('only offers options listed for the year, plus unknown-availability ones as unverified', () => {
    const ids = (y: 2020 | 2021 | 2022) => optionsFor(y).map((o) => o.pkg.id);
    expect(ids(2021)).toContain('cfhp');
    expect(ids(2020)).not.toContain('cfhp');
    expect(ids(2022)).toContain('heritage-pkg');
    expect(ids(2021)).not.toContain('heritage-pkg');
    expect(optionsFor(2022).find((o) => o.pkg.id === 'convenience')?.availability).toBe('unverified');
    expect(optionsFor(2022).find((o) => o.pkg.id === 'cftp')?.availability).toBe('listed');
  });
  it('ignores selected options not offered for the year', () => {
    expect(buildSticker(2020, ['cfhp']).lines.some((l) => l.id === 'cfhp')).toBe(false);
  });
  it('works on synthetic packages', () => {
    const p: OptionPackage = { id: 'x', name: 'X', years: [], source: 'https://e.com', confidence: 'reported', price: { value: 5, source: 'https://e.com', confidence: 'reported' }, contents: [], contentsConfidence: 'reported' };
    expect(buildSticker(2021, ['x'], [p], []).total).toBe(5);
    expect(buildSticker(2021, ['x'], [p], []).unpriced).toBe(3);
  });
});

describe('storage', () => {
  it('saves and loads the last build, normalizing bad data, without a backup schema bump', () => {
    expect(loadBuild()).toEqual({ year: 2020, options: [] });
    saveBuild({ year: 2022, options: ['cftp', 'cftp'] });
    expect(loadBuild()).toEqual({ year: 2022, options: ['cftp'] });
    expect(normBuild({ year: 1999, options: [] })).toBeNull();
    store.set(BUILD_KEY, '{"year":2021,"options":["<b>",1,"tech"]}');
    expect(loadBuild()).toEqual({ year: 2021, options: ['tech'] });
    expect(ALL_KEYS).toContain(BUILD_KEY);
    expect(SCHEMA_VERSION).toBe(11);
  });
});

describe('i18n, nav, search, render', () => {
  it('every build.* key has a Spanish translation', () => {
    const keys = Object.keys(en).filter((k) => k.startsWith('build.') || k === 'nav.build' || k === 'help.tool.build');
    expect(keys.length).toBeGreaterThan(20);
    for (const k of keys) expect(es[k as keyof typeof es], k).toBeTruthy();
  });
  it('menu and search reach the page', () => {
    expect(NAV.some((n) => n.to === '/build-sheet')).toBe(true);
    expect(search('window sticker').some((r) => r.route === '/build-sheet')).toBe(true);
  });
  it('renders en and es', () => {
    const h = wrap(<BuildSheet />);
    expect(h).toContain('Build &amp; Sticker');
    expect(h).toContain('$73,995');
    const h2 = wrap(<BuildSheet />, 'es');
    expect(h2).toContain('Configuración y etiqueta');
    expect(h2).toContain('MSRP base');
    store.set(BUILD_KEY, JSON.stringify({ year: 2021, options: [] }));
    const h3 = wrap(<BuildSheet />);
    expect(h3).toContain('at least $71,495');
    expect(h3).toContain('price not sourced');
  });
});
