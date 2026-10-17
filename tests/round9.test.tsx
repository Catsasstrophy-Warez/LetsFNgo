import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { readFileSync } from 'node:fs';
import { MemoryRouter, Route, Routes } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import type { Lang } from '../src/lib/i18n';
import { REPORT_CSP, buildReport, reportHtml } from '../src/lib/report';
import { translate } from '../src/lib/i18n';
import { escapeText, remindersToIcs } from '../src/lib/ics';
import { csvCell } from '../src/lib/factExport';
import { normNotify } from '../src/lib/validate';
import { dueAlerts } from '../src/lib/notify';
import { parseMoney, usdFixed, usdRange, usdWhole } from '../src/lib/format';
import { parseMoney as fuelMoney } from '../src/lib/fuel';
import { usd0 } from '../src/lib/market';
import { DEFAULT_EDITION_FILTER, DEFAULT_FP_FILTER, filterEditions, filterFp, historyTimeline } from '../src/lib/catalog';
import { DISMISS_DAYS, INSTALL_KEY, dismissInstall, installMode, isDismissed, isIosSafari, isStandalone, loadInstall } from '../src/lib/install';
import { ALL_KEYS } from '../src/lib/backup';
import { editions, editionGaps } from '../src/data/editions';
import { events, historyGaps, milestones } from '../src/data/history';
import { FITMENT_INFERRED, FP_AS_OF, fpCatalog } from '../src/data/parts';
import { collections } from '../src/data';
import { EMPTY_GARAGE, type Car } from '../src/lib/garage';
import config from '../capacitor.config';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); } });
afterAll(() => vi.unstubAllGlobals());
beforeEach(() => store.clear());

const tEn = (k: Parameters<typeof translate>[1], v?: Record<string, string | number>) => translate('en', k, v);
const car = (over: Partial<Car> = {}): Car => ({ ...EMPTY_GARAGE, id: 'car1', ...over });

describe('security regressions', () => {
  it('downloaded report: hostile owner text is escaped and the file carries a no-script CSP', () => {
    const evil = '<img src=x onerror=alert(1)><script>alert(2)</script>"\'';
    const m = buildReport(car({ nickname: evil, service: [{ id: 's', date: '2025-01-01', title: evil, notes: evil, miles: '1', cost: evil }] }), [], '2026-10-16');
    const html = reportHtml(m, tEn, 'imperial', 'en');
    expect(html).not.toContain('<img');
    expect(html).not.toContain('<script');
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
    expect(html).toContain(`content="${REPORT_CSP}"`);
    expect(REPORT_CSP).toMatch(/default-src 'none'/);
    expect(REPORT_CSP).not.toMatch(/script-src/);
    expect(html).toContain('name="referrer" content="no-referrer"');
  });
  it('ICS: control characters are dropped and newlines cannot start a new property', () => {
    expect(escapeText('a\u0000b\u0007c\td')).toBe('abc\td');
    const r = remindersToIcs([{ id: 'car1', label: 'x', odometer: null, reminders: [{ id: 'r', item: 'Oil\r\nATTACH:http://evil\u0001', everyMiles: null, everyMonths: 6, lastMiles: null, lastDate: '2026-01-01' }] }], '2026-02-01');
    expect(r.ics).not.toMatch(/\r\nATTACH:/);
    expect(r.ics).toContain('Oil\\nATTACH:http://evil');
    expect(r.ics).not.toContain('\u0001');
  });
  it('CSV: formula prefixes are neutralised, including after leading whitespace and newlines', () => {
    for (const s of ['=1+1', '+1', '-1', '@SUM(A1)', '\t=1', ' =HYPERLINK("x")', '\n=1']) expect(csvCell(s).replace(/^"/, '')).toMatch(/^'/);
    expect(csvCell('plain, text')).toBe('"plain, text"');
    expect(csvCell('760 hp')).toBe('760 hp');
  });
  it('notify prefs import: prototype keys are ignored and values are capped', () => {
    const raw = JSON.parse('{"enabled":true,"sent":{"__proto__":"x","constructor":"y","ok":"soon|1|"}}');
    const n = normNotify(raw)!;
    expect(Object.keys(n.sent)).toEqual(['ok']);
    expect(Object.getPrototypeOf(n.sent)).toBe(Object.prototype);
    expect(normNotify({ enabled: true, sent: { a: 'x'.repeat(500) } })!.sent).toEqual({});
  });
  it('notification titles are plain text and length-capped', () => {
    const a = dueAlerts([{ id: 'r', item: 'x'.repeat(500), everyMiles: null, everyMonths: 1, lastMiles: null, lastDate: '2020-01-01' }], null, '2026-10-16', {});
    expect(a[0].title.length).toBeLessThanOrEqual(120);
  });
  it('index.html CSP: no inline styles or scripts, no plugins, no form posts', () => {
    const csp = /Content-Security-Policy" content="([^"]+)"/.exec(readFileSync('index.html', 'utf8'))![1];
    expect(csp).not.toContain("'unsafe-inline'");
    expect(csp).not.toContain("'unsafe-eval'");
    for (const d of ["object-src 'none'", "base-uri 'self'", "form-action 'none'", "script-src 'self'", "style-src 'self'", "script-src-attr 'none'"]) expect(csp).toContain(d);
  });
  it('Capacitor: https scheme, no cleartext, no remote navigation, no mixed content or release debugging', () => {
    expect(config.server).toMatchObject({ androidScheme: 'https', cleartext: false, allowNavigation: [] });
    expect(config.android).toMatchObject({ allowMixedContent: false, webContentsDebuggingEnabled: false });
    expect(JSON.stringify(config)).not.toMatch(/http:\/\//);
  });
  it('service worker: notification clicks only open in-scope URLs; only same-origin GETs are cached', () => {
    const sw = readFileSync('public/sw.js', 'utf8');
    expect(sw).toContain("new URL('./#/garage', self.registration.scope)");
    expect(sw).not.toMatch(/notification\.data/);
    expect(sw).toContain('url.origin !== self.location.origin');
  });
  it('every sourced URL (all collections, nested) is https — no javascript: or data: hrefs can reach a link', () => {
    const urls: string[] = [];
    const walk = (v: unknown) => { if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { if (k === 'source' || k === 'licenseUrl') urls.push(x as string); walk(x); } };
    walk(Object.values(collections));
    expect(urls.length).toBeGreaterThan(100);
    for (const u of urls) expect(u, u).toMatch(/^https:\/\/[^\s"<>]+$/);
  });
});

describe('format helpers keep the old outputs', () => {
  it('money formatting', () => {
    expect(usdWhole(1234.5)).toBe('$1,235');
    expect(usd0(99999.4)).toBe('$99,999');
    expect(usdFixed(1234.5)).toBe('$1,234.50');
    expect(usdFixed(0.1234, 3)).toBe('$0.123');
    expect(usdRange(399, 399)).toBe('$399');
    expect(usdRange(399, 1399.99)).toBe('$399–$1,400');
  });
  it('money parsing: null variant for timeline/report, positive-only for fuel', () => {
    expect(parseMoney('$1,200')).toBe(1200);
    expect(parseMoney(' 950 ')).toBe(950);
    expect(parseMoney('')).toBeNull();
    expect(parseMoney('  ')).toBeNull();
    expect(parseMoney('abc')).toBeNull();
    expect(parseMoney(undefined)).toBeNull();
    expect(parseMoney('-5')).toBe(-5);
    expect(fuelMoney('-5')).toBe(0);
    expect(fuelMoney('$12.50')).toBe(12.5);
    expect(fuelMoney(undefined)).toBe(0);
  });
});

describe('round-8 data slots', () => {
  it('editions keep round-8 source, research level and nulls; Super Snake stays a gap', () => {
    expect(editions.map((e) => e.id)).toEqual(['gt500se', 'gt500kr', 'code-red']);
    const [se, kr, cr] = editions;
    expect([se.research, kr.research, cr.research]).toEqual(['high', 'medium', 'medium']);
    expect([se.confidence, kr.confidence, cr.confidence]).toEqual(['confirmed', 'reported', 'reported']);
    expect(se.price).toBe(29995); expect(kr.price).toBe(127895); expect(kr.upfitPrice).toBe(54995); expect(cr.price).toBe(209995);
    expect(kr.content).toBeNull();
    expect(cr.streetLegal).toBe(false);
    expect(kr.productionConflicts!.map((c) => c.value)).toEqual([
      '225 total: 180 US (60 per model year) + 45 overseas', '225 total incl. 45 overseas', '120 retrofits plus 60 new', '120 retrofits plus 60 new', '180 US cars across MY2021-2022',
    ]);
    expect(editions.some((e) => /Super Snake/.test(e.name))).toBe(false);
    expect(editionGaps.join()).toMatch(/Super Snake/);
  });
  it('Ford Performance catalog: 18 items, current MSRP dated, emissions unknown, 12 inferred-fitment caveats', () => {
    expect(fpCatalog).toHaveLength(18);
    expect(FP_AS_OF).toBe('2026-10-16');
    expect(fpCatalog.every((p) => p.emissions === null && p.priceAsOf === FP_AS_OF && p.source === 'https://performanceparts.ford.com/search/GT500' && /^M-/.test(p.number))).toBe(true);
    const inferred = fpCatalog.filter((p) => !p.fitmentExplicit);
    expect(inferred).toHaveLength(12);
    expect(inferred.every((p) => p.note === FITMENT_INFERRED && p.research === 'medium' && p.confidence === 'reported')).toBe(true);
    expect(fpCatalog.filter((p) => p.fitmentExplicit).every((p) => p.research === 'high' && p.confidence === 'confirmed')).toBe(true);
    expect(fpCatalog.find((p) => p.number === 'M-9926-M5292')!.fitmentYears).toEqual([2020, 2021]);
    expect(fpCatalog.find((p) => p.number === 'M-4130-MA')!.msrp).toBe(2575);
  });
  it('events and milestones keep nulls; 10Best and Track Attack years are not invented', () => {
    expect(events.find((e) => e.id === 'track-attack')!.date).toBeNull();
    expect(milestones.find((m) => m.id === 'mt-bdc-2020')!.placement).toBeNull();
    expect(milestones.find((m) => m.id === 'mt-bdc-2020')!.research).toBe('low');
    expect(milestones.some((m) => /10Best/.test(m.title))).toBe(false);
    expect(historyGaps.join()).toMatch(/10Best/);
  });
  it('filters and timeline ordering', () => {
    expect(filterEditions(editions, { ...DEFAULT_EDITION_FILTER, streetLegalOnly: true }).map((e) => e.id)).toEqual(['gt500se', 'gt500kr']);
    expect(filterEditions(editions, { ...DEFAULT_EDITION_FILTER, confidence: 'confirmed' })).toHaveLength(1);
    expect(filterFp(fpCatalog, { ...DEFAULT_FP_FILTER, q: 'm6766' }).map((p) => p.number)).toEqual(['M-6766-A52']);
    expect(filterFp(fpCatalog, { ...DEFAULT_FP_FILTER, explicitOnly: true })).toHaveLength(6);
    expect(filterFp(fpCatalog, { ...DEFAULT_FP_FILTER, year: 2022, explicitOnly: true })).toHaveLength(5);
    const tl = historyTimeline(events, milestones);
    expect(tl[0].id).toBe('reveal');
    expect(tl[tl.length - 1].date).toBeNull();
    expect(historyTimeline(events, milestones, 'milestone').every((x) => x.kind === 'milestone')).toBe(true);
    expect(historyTimeline([], [])).toEqual([]);
  });
});

describe('install prompt', () => {
  it('remembers a dismissal for 90 days; bad stored values are ignored', () => {
    expect(loadInstall()).toEqual({ dismissed: null });
    dismissInstall('2026-10-16');
    expect(isDismissed(loadInstall(), '2026-10-17')).toBe(true);
    expect(isDismissed(loadInstall(), '2027-01-13')).toBe(true);
    expect(isDismissed(loadInstall(), '2027-01-14')).toBe(false);
    expect(DISMISS_DAYS).toBe(90);
    store.set(INSTALL_KEY, '{"dismissed":"<b>"}');
    expect(loadInstall().dismissed).toBeNull();
    expect(ALL_KEYS).toContain(INSTALL_KEY);
  });
  it('picks prompt / iOS hint / nothing', () => {
    const base = { hasPrompt: false, ios: false, standalone: false, native: false, dismissed: false };
    expect(installMode({ ...base, hasPrompt: true })).toBe('prompt');
    expect(installMode({ ...base, ios: true })).toBe('ios');
    expect(installMode({ ...base, ios: true, standalone: true })).toBeNull();
    expect(installMode({ ...base, hasPrompt: true, dismissed: true })).toBeNull();
    expect(installMode({ ...base, hasPrompt: true, native: true })).toBeNull();
    expect(installMode(base)).toBeNull();
    expect(isIosSafari('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1')).toBe(true);
    expect(isIosSafari('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) CriOS/120 Mobile Safari/604.1')).toBe(false);
    expect(isIosSafari('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/17.0 Safari/605.1.15', 5)).toBe(true);
    expect(isIosSafari('Mozilla/5.0 (Linux; Android 14) Chrome/120 Mobile Safari/537.36')).toBe(false);
    expect(isStandalone({ matchMedia: () => ({ matches: true }) })).toBe(true);
    expect(isStandalone({ matchMedia: () => ({ matches: false }), navigator: { standalone: true } })).toBe(true);
  });
  it('manifest: app shortcuts and separate, full-bleed maskable icons', () => {
    const m = JSON.parse(readFileSync('public/manifest.webmanifest', 'utf8'));
    expect(m.shortcuts.map((s: { url: string }) => s.url)).toEqual(['./#/garage', './#/timer', './#/vin']);
    const mask = m.icons.filter((i: { purpose: string }) => i.purpose === 'maskable');
    expect(mask.map((i: { sizes: string }) => i.sizes)).toEqual(['192x192', '512x512']);
    expect(m.icons.some((i: { purpose: string }) => i.purpose === 'any maskable')).toBe(false);
    expect(readFileSync('public/icon-maskable.svg', 'utf8')).not.toMatch(/rx=/);
    for (const f of ['icon-only', 'icon-foreground', 'icon-background', 'splash', 'splash-dark']) expect(readFileSync(`resources/${f}.svg`, 'utf8')).toMatch(/^<svg/);
  });
});

async function render(name: string, lang: Lang = 'en', path = '/', props: Record<string, unknown> = {}) {
  const { PAGES } = await import('../src/App');
  const { default: Page } = await PAGES[name as keyof typeof PAGES]() as { default: (p: Record<string, unknown>) => JSX.Element };
  return renderToString(
    <SettingsContext.Provider value={{ settings: { units: 'imperial', theme: 'dark', lang }, setSettings: () => undefined }}>
      <MemoryRouter initialEntries={[path]}><Routes><Route path="/" element={<Page {...props} />} /></Routes></MemoryRouter>
    </SettingsContext.Provider>,
  ).replace(/<!-- -->/g, '');
}

describe('round-8 pages render', () => {
  it('Editions: cards, conflict, gaps; empty state', async () => {
    const h = await render('Editions');
    for (const s of ['Shelby American Editions', 'GT500SE', 'GT500KR', 'Code Red', '$29,995', '$54,995', '120 retrofits plus 60 new', 'Super Snake', 'research level: high']) expect(h).toContain(s);
    const e = await render('Editions', 'en', '/', { editions: [], gaps: [] });
    expect(e).toContain('No editions yet');
    expect(e).not.toContain('GT500KR');
    expect(await render('Editions', 'es')).toContain('Ediciones de Shelby American');
  });
  it('History: vertical timeline in date order; empty state', async () => {
    const h = await render('History');
    expect(h).toContain('<ol class="timeline hist">');
    expect(h.indexOf('NAIAS')).toBeLessThan(h.indexOf('SAAC-46'));
    expect(h).toContain('Final placement: unknown');
    expect(h).toContain('Date unknown');
    expect(await render('History', 'en', '/', { events: [], milestones: [], gaps: [] })).toContain('No events yet');
    expect(await render('History', 'es')).toContain('Eventos e historia');
  });
  it('Parts: Ford Performance tab lists M-numbers with MSRP, emissions and fitment; empty state', async () => {
    const fluids = await render('Parts');
    expect(fluids).toContain('FL-2087');
    expect(fluids).toContain('role="tablist"');
    const h = await render('Parts', 'en', '/?tab=fp');
    for (const s of ['M-16612-C20', '$1,360', 'MSRP as of 2026-10-16', 'unknown (not shown by the catalog)', 'fitment inferred', '18 of 18 parts']) expect(h).toContain(s);
    expect(h).not.toContain('FL-2087');
    expect(await render('Parts', 'en', '/?tab=fp', { fp: [] })).toContain('No Ford Performance parts yet');
    expect(await render('Parts', 'es', '/?tab=fp')).toContain('compatibilidad inferida');
  });
  it('Help explains tools, badges, privacy and backups in both languages', async () => {
    const h = await render('Help');
    for (const s of ['Help &amp; Guide', 'Confidence badges', 'confirmed', 'unverified', 'Data privacy', 'never uploaded', 'Export JSON', 'VIN Decoder']) expect(h).toContain(s);
    const es = await render('Help', 'es');
    for (const s of ['Ayuda y guía', 'Privacidad de datos', 'nunca se suben']) expect(es).toContain(s);
  });
});
