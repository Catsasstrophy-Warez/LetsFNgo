import { beforeEach, describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { readFileSync, readdirSync } from 'node:fs';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import type { Lang } from '../src/lib/i18n';
import { collections } from '../src/data';
import type { Sourced } from '../src/data/types';
import { SCHEMAS, checkCollections, validateSchema } from '../src/lib/dataSchema';
import { computeCoverage, percentages, routeFor } from '../src/lib/coverage';
import { parseMoney } from '../src/lib/format';
import { parseMoney as fuelMoney } from '../src/lib/fuel';
import { isIosSafari } from '../src/lib/install';
import { historyTimeline } from '../src/lib/catalog';
import { LineChart } from '../src/components/LineChart';
import { ScatterChart } from '../src/components/ScatterChart';
import { DynoChart } from '../src/components/DynoChart';
import type { DynoPull } from '../src/lib/dyno';
import Coverage from '../src/pages/Coverage';
import Gallery from '../src/pages/Gallery';
import { en, setCurrentLang } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { NAV } from '../src/App';

const wrap = (el: JSX.Element, lang: Lang = 'en') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang }, setSettings: () => undefined }}>
    <MemoryRouter>{el}</MemoryRouter>
  </SettingsContext.Provider>,
);
const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x));

describe('data schemas + validate:data', () => {
  it('every collection has a schema and the committed schemas/ files match src/lib/dataSchema.ts', () => {
    expect(Object.keys(SCHEMAS).sort()).toEqual(Object.keys(collections).sort());
    const files = readdirSync('schemas').filter((f) => f.endsWith('.schema.json')).map((f) => f.replace('.schema.json', '')).sort();
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
    for (const [name, s] of Object.entries(SCHEMAS)) expect(readFileSync(`schemas/${name}.schema.json`, 'utf8'), name).toBe(JSON.stringify(s, null, 2) + '\n');
  });
  it('the shipped data passes every check', () => {
    expect(checkCollections(collections)).toEqual([]);
  });
  it('catches http sources, bad confidence, unknown fields, unexplained nulls, dupes and broken conflicts', () => {
    const c = clone(collections) as unknown as Record<string, Record<string, unknown>[]>;
    c.colors[0].source = 'http://example.com/x';
    c.colors[1].confidence = 'probably';
    c.colors[2].extra = 1;
    c.specs[0].value = null; delete c.specs[0].note;
    c.communities.push(clone(c.communities[0]));
    const cw = c.specs.find((s) => s.id === 'curb-weight')!;
    cw.conflicts = [{ value: cw.value, source: cw.source, confidence: 'confirmed' }];
    c.editions[0].confidence = c.editions[0].research === 'high' ? 'unverified' : 'confirmed';
    const msgs = checkCollections(c as unknown as Record<string, Sourced[]>).map((i) => `${i.collection} ${i.path}: ${i.message}`).join('\n');
    expect(msgs).toMatch(/colors \$\[0\]\.source/);
    expect(msgs).toMatch(/colors \$\[1\]\.confidence/);
    expect(msgs).toMatch(/unknown field "extra"/);
    expect(msgs).toMatch(/null value needs a note/);
    expect(msgs).toMatch(/duplicate id/);
    expect(msgs).toMatch(/at least two different sourced values/);
    expect(msgs).toMatch(/research level/);
  });
  it('validator handles anyOf, enum, pattern, minItems and $ref', () => {
    const s = { type: 'object', required: ['a'], properties: { a: { anyOf: [{ type: 'number' }, { type: 'null' }] }, b: { $ref: '#/$defs/x' }, c: { type: 'array', items: { enum: [1] }, minItems: 1 } }, additionalProperties: false, $defs: { x: { type: 'string', pattern: '^z' } } };
    expect(validateSchema(s, { a: null, b: 'zz', c: [1] })).toEqual([]);
    expect(validateSchema(s, { a: 'x', b: 'q', c: [] }).length).toBe(3);
    expect(validateSchema(s, {})).toEqual(['$: missing required field "a"']);
  });
  it('npm script, CI step and contribution docs exist', () => {
    const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
    expect(pkg.scripts['validate:data']).toBeTruthy();
    expect(pkg.scripts['check:links']).toBeTruthy();
    expect(readFileSync('.github/workflows/ci.yml', 'utf8')).toContain('npm run validate:data');
    expect(readFileSync('CONTRIBUTING.md', 'utf8')).toContain('validate:data');
    expect(readFileSync('.github/ISSUE_TEMPLATE/data-correction.yml', 'utf8')).toContain('source');
  });
  it('link-check workflow only runs on demand / weekly and never fails or commits', () => {
    const w = readFileSync('.github/workflows/links.yml', 'utf8');
    expect(w).toMatch(/workflow_dispatch/);
    expect(w).toMatch(/schedule/);
    expect(w).not.toMatch(/^\s*(push|pull_request):/m);
    expect(w).toContain('contents: read');
    expect(w).not.toMatch(/git (commit|push)/);
    expect(w).toContain('upload-artifact');
  });
});

describe('coverage', () => {
  const cov = computeCoverage(collections);
  it('totals add up and every fact is counted once per confidence', () => {
    const facts = cov.sections.reduce((a, s) => a + s.facts, 0);
    expect(cov.totals.facts).toBe(facts);
    expect(cov.totals.counts.confirmed + cov.totals.counts.reported + cov.totals.counts.unverified).toBe(facts);
    expect(cov.domains.reduce((a, d) => a + d.facts, 0)).toBe(facts);
    expect(cov.totals.records).toBe(Object.values(collections).reduce((a, r) => a + r.length, 0));
  });
  it('lists null fields with the note as what is needed, and links them to their page', () => {
    const g = cov.gaps.find((x) => x.collection === 'auctionResults');
    expect(g?.route).toBe('/market');
    expect(cov.gaps.every((x) => x.route.startsWith('/'))).toBe(true);
    const sv = cov.gaps.find((x) => x.collection === 'specs');
    if (sv) expect(sv.need).toBeTruthy();
    expect(routeFor('guides', { id: 'oil' })).toBe('/guides/oil');
    expect(routeFor('fpCatalog', {})).toBe('/parts?tab=fp');
  });
  it('lists conflicts including curb weight', () => {
    const cw = cov.conflicts.find((c) => c.id === 'curb-weight');
    expect(cw?.values.length).toBeGreaterThanOrEqual(3);
  });
  it('percentages always total 100', () => {
    expect(percentages({ confirmed: 1, reported: 1, unverified: 1 })).toEqual({ confirmed: 34, reported: 33, unverified: 33 });
    expect(percentages({ confirmed: 0, reported: 0, unverified: 0 })).toEqual({ confirmed: 0, reported: 0, unverified: 0 });
  });
  it('page renders in English and Spanish and is in the menu', () => {
    const h = wrap(<Coverage />);
    for (const s of ['Data Coverage', 'Confidence by section', 'Conflicts (', 'Source domains', 'href="/market"']) expect(h).toContain(s);
    expect(wrap(<Coverage />, 'es')).toContain('Cobertura de datos');
    expect(NAV.some((n) => n.to === '/coverage')).toBe(true);
  });
});

describe('chart accessibility', () => {
  beforeEach(() => setCurrentLang('en'));
  const pts = [{ label: 'a', value: 1 }, { label: 'b', value: 3 }, { label: 'c', value: 2 }];
  it('line chart: group role, roving-tabindex points with labels, visually hidden table', () => {
    const h = renderToString(<LineChart title="T" points={pts} format={(v) => v.toFixed(1)} unit="s" />);
    expect(h).toContain('role="group"');
    expect(h).not.toMatch(/<svg[^>]*role="img"/);
    expect((h.match(/tabindex="0"/g) ?? []).length).toBe(1);
    expect((h.match(/tabindex="-1"/g) ?? []).length).toBe(2);
    expect(h).toContain('aria-label="b: 3.0 s (best)"');
    expect(h).toMatch(/class="sr-only"[^>]*><table/);
    expect(h).toContain('aria-expanded="false"');
  });
  it('scatter chart points follow x order', () => {
    const h = renderToString(<ScatterChart title="S" points={[{ id: '2', x: 5, y: 1, label: 'late' }, { id: '1', x: 1, y: 2, label: 'early' }]} fmtX={String} fmtY={String} xLabel="x" yLabel="y" tableLabel="tbl" empty="none" />);
    expect(h.indexOf('aria-label="early: 2"')).toBeLessThan(h.indexOf('aria-label="late: 1"'));
    expect(h).toMatch(/data-pt="0"[^>]*tabindex="0"/);
  });
  it('dyno chart has focusable points and a hidden table', () => {
    const pull = { id: 'p', curve: [{ rpm: 3000, hp: 300, tq: 500 }, { rpm: 6000, hp: 600, tq: null }] } as unknown as DynoPull;
    const h = renderToString(<DynoChart pulls={[pull]} label={() => 'P'} />);
    expect(h).toContain('aria-label="P · 3000 rpm: 300 whp, 500 lb-ft"');
    expect(h).toContain('class="sr-only"');
  });
  it('reduced motion is respected in CSS', () => {
    expect(readFileSync('src/styles.css', 'utf8')).toMatch(/prefers-reduced-motion: reduce/);
  });
});

describe('gallery + i18n', () => {
  it('gallery renders both themes', () => {
    const h = wrap(<Gallery />);
    expect(h).toContain('data-theme="dark"');
    expect(h).toContain('data-theme="light"');
  });
  it('gallery is dev-only in App', () => {
    expect(readFileSync('src/App.tsx', 'utf8')).toMatch(/import\.meta\.env\.DEV \? lazy\(\(\) => import\('\.\/pages\/Gallery'\)\) : null/);
  });
  it('every new key is translated', () => {
    for (const k of Object.keys(en).filter((k) => /^(cov|gal)\.|^nav\.coverage|^chart\.(show|hide)Table/.test(k))) expect(es[k as keyof typeof es], k).toBeTruthy();
  });
});

describe('bug-hunt regressions', () => {
  it('a bare "$" or "," is not parsed as $0', () => {
    expect(parseMoney('$')).toBeNull();
    expect(parseMoney(',')).toBeNull();
    expect(parseMoney('$1,200')).toBe(1200);
    expect(fuelMoney('$')).toBe(0);
  });
  it('in-app iOS browsers (Google app, Facebook, Instagram) do not get the Add to Home Screen hint', () => {
    expect(isIosSafari('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) GSA/300.0 Mobile/15E148 Safari/604.1')).toBe(false);
    expect(isIosSafari('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 [FBAN/FBIOS;FBAV/400.0] Safari/604.1')).toBe(false);
  });
  it('history timeline orders by plain string comparison, partial dates first within a year', () => {
    const mk = (id: string, date: string | null) => ({ id, date, title: id, source: 'https://x.y', confidence: 'reported' as const, research: 'medium' as const });
    const out = historyTimeline([], [mk('c', '2020-01-05'), mk('n', null), mk('a', '2020'), mk('b', '2020-01')]).map((x) => x.id);
    expect(out).toEqual(['a', 'b', 'c', 'n']);
  });
  it('Parts: switching tabs keeps the fluids search', () => {
    expect(readFileSync('src/pages/Parts.tsx', 'utf8')).toContain('...(q ? { q } : {})');
  });
});
