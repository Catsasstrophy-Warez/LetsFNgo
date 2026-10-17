import { afterEach, describe, expect, it, vi } from 'vitest';
import { convertSpec, fmtQty, fromDisplay, normalizeSettings, resolveTheme, toDisplay, type Kind } from '../src/lib/units';
import { correctToSeaLevel, densityAltitude, densityRatioAt, dragStats, parsePass, satVaporPressure, stationPressure, stockPasses, type Timeslip } from '../src/lib/drag';
import { fuelIntervals, fuelSummary, ownershipCost, parseMoney, type FillUp } from '../src/lib/fuel';
import { buildQuestions, quizRound, recordAnswer, rng, EMPTY_SCORE } from '../src/lib/quiz';
import { paintInfo, paintsFor, stripeFor } from '../src/lib/paint';
import { MAX_IMPORT_BYTES, SCHEMA_VERSION, makeBackup, migrate, parseBackup, validateBackup } from '../src/lib/backup';
import { normGarage, normScore, normSlip, normTrack } from '../src/lib/validate';
import { EMPTY_GARAGE, today } from '../src/lib/garage';
import { formatLapTime } from '../src/lib/laptime';
import { fitText } from '../src/lib/shareCard';
import { isYouTubeId } from '../src/components/YouTube';
import { _resetForTests, applyUpdate, onUpdateReady, watchRegistration, type RegLike } from '../src/lib/sw';
import { collections, collectSourced } from '../src/data';
import { specs } from '../src/data/specs';
import { recalls } from '../src/data/recalls';
import { maintenance } from '../src/data/maintenance';
import { colors } from '../src/data/colors';
import { media } from '../src/data/media';

const slip = (p: Partial<Timeslip>): Timeslip => ({
  id: Math.random().toString(36), date: '2026-01-01', track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null,
  weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false }, mods: [], notes: '', ...p,
});
const fill = (odometer: number, gallons: number, price = 4, full = true): FillUp => ({ id: String(odometer), date: `d${odometer}`, odometer, gallons, price, fuel: '93', blend: null, full, notes: '' });

describe('units', () => {
  it('round-trips every kind', () => {
    for (const k of ['distance', 'speed', 'weight', 'length', 'volume', 'temp', 'pressure', 'altitude', 'torque', 'economy', 'shortLength'] as Kind[])
      expect(fromDisplay(k, toDisplay(k, 123.4, 'metric'), 'metric')).toBeCloseTo(123.4, 6);
  });
  it('converts known values', () => {
    expect(toDisplay('distance', 1, 'metric')).toBeCloseTo(1.609344, 6);
    expect(toDisplay('temp', 212, 'metric')).toBeCloseTo(100, 6);
    expect(toDisplay('pressure', 29.92, 'metric')).toBeCloseTo(1013.2, 1);
    expect(toDisplay('economy', 14, 'metric')).toBeCloseTo(16.8, 1);
    expect(toDisplay('weight', 4225, 'imperial')).toBe(4225);
    expect(fmtQty('speed', 133, 'metric')).toBe('214 km/h');
    expect(fmtQty('speed', null, 'metric')).toBe('—');
  });
  it('converts spec strings and keeps the rest of the unit', () => {
    expect(convertSpec('4,006–4,225', 'lb', 'metric')).toEqual({ value: '1,817–1,916', unit: 'kg' });
    expect(convertSpec(625, 'lb-ft @ 5,000 rpm', 'metric')).toEqual({ value: '847', unit: 'N·m @ 5,000 rpm' });
    expect(convertSpec(180, 'mph (electronically limited)', 'metric').unit).toBe('km/h (electronically limited)');
    expect(convertSpec(760, 'hp @ 7,300 rpm', 'metric')).toEqual({ value: 760, unit: 'hp @ 7,300 rpm' });
    expect(convertSpec(107.1, 'in', 'imperial')).toEqual({ value: 107.1, unit: 'in' });
  });
  it('normalizes settings and theme', () => {
    expect(normalizeSettings({ units: 'metric', theme: 'system' })).toEqual({ units: 'metric', theme: 'system', lang: 'en', accent: 'default' });
    expect(normalizeSettings({ units: 5, theme: {} })).toEqual({ units: 'imperial', theme: 'dark', lang: 'en', accent: 'default' });
    expect(normalizeSettings(null)).toEqual({ units: 'imperial', theme: 'dark', lang: 'en', accent: 'default' });
    expect(resolveTheme('system', false)).toBe('light');
    expect(resolveTheme('dark', false)).toBe('dark');
  });
});

describe('density altitude', () => {
  it('is ~0 ft on a standard day', () => {
    const r = densityAltitude({ tempF: 59, pressureInHg: 29.92, humidity: 0, elevationFt: 0 })!;
    expect(Math.abs(r.daFt)).toBeLessThan(30);
    expect(r.densityRatio).toBeCloseTo(1, 2);
  });
  it('matches the ~120 ft per °C rule of thumb on a hot dry day', () => {
    const r = densityAltitude({ tempF: 90, pressureInHg: 29.92, humidity: 0, elevationFt: 0 })!;
    expect(r.daFt).toBeGreaterThan(1900); expect(r.daFt).toBeLessThan(2150);
  });
  it('humidity and elevation raise DA; station pressure skips elevation', () => {
    const dry = densityAltitude({ tempF: 85, pressureInHg: 29.92, humidity: 0, elevationFt: 1000 })!.daFt;
    const wet = densityAltitude({ tempF: 85, pressureInHg: 29.92, humidity: 80, elevationFt: 1000 })!.daFt;
    expect(wet - dry).toBeGreaterThan(200); expect(wet - dry).toBeLessThan(700);
    const st = stationPressure(1013.25, 1000 * 0.3048) / 33.8638866667;
    const asStation = densityAltitude({ tempF: 85, pressureInHg: st, humidity: 0, elevationFt: 9999, pressureIsStation: true })!.daFt;
    expect(Math.abs(asStation - dry)).toBeLessThan(5);
    // ISA at 5,000 ft (41.2 °F, 24.90 inHg station) → DA ≈ 5,000 ft
    expect(densityAltitude({ tempF: 41.17, pressureInHg: 24.896, humidity: 0, elevationFt: 0, pressureIsStation: true })!.daFt).toBeCloseTo(5000, -2);
  });
  it('validates input', () => {
    expect(densityAltitude({ tempF: NaN, pressureInHg: 29.92, humidity: 0, elevationFt: 0 })).toBeNull();
    expect(densityAltitude({ tempF: 70, pressureInHg: 29.92, humidity: 120, elevationFt: 0 })).toBeNull();
    expect(satVaporPressure(20)).toBeCloseTo(23.4, 1);
  });
  it('estimates a sea-level ET', () => {
    expect(densityRatioAt(0)).toBeCloseTo(1, 6);
    const c = correctToSeaLevel(11.0, 125, 3000)!;
    expect(c.et).toBeLessThan(11.0); expect(c.et).toBeGreaterThan(10.6); expect(c.mph!).toBeGreaterThan(125);
    expect(correctToSeaLevel(11, null, -1000)!.et).toBeGreaterThan(11);
    expect(correctToSeaLevel(0, 1, 0)).toBeNull();
  });
});

describe('drag stats and stock passes', () => {
  it('best and consistency', () => {
    const s = dragStats([slip({ quarterEt: 11.2, quarterMph: 128, rt: 0.5, sixty: 1.7 }), slip({ quarterEt: 11.0, quarterMph: 130, rt: 0.45, sixty: 1.65 }), slip({ quarterEt: 11.1, quarterMph: 129 }), slip({ eighthEt: 7 })]);
    expect(s).toMatchObject({ count: 4, bestEt: 11.0, bestMph: 130, bestRt: 0.45, bestSixty: 1.65 });
    expect(s.meanEt).toBeCloseTo(11.1, 6); expect(s.sdEt).toBeCloseTo(0.1, 6); expect(s.spreadEt).toBeCloseTo(0.2, 6);
    expect(dragStats([])).toMatchObject({ count: 0, bestEt: null, sdEt: null });
  });
  it('parses sourced passes, stock only, no unverified', () => {
    expect(parsePass('10.61 s @ 133 mph')).toEqual({ et: 10.61, mph: 133 });
    expect(parsePass('0–60 3.4 s · 0–100 6.9 s · ¼ 11.3 s')).toEqual({ et: 11.3, mph: null });
    const p = stockPasses();
    expect(p.find((x) => x.record.id === 'best-stock')).toMatchObject({ et: 10.61, mph: 133 });
    expect(p.every((x) => x.record.car.startsWith('stock') && x.record.confidence !== 'unverified')).toBe(true);
    expect(p.length).toBeGreaterThanOrEqual(4);
  });
});

describe('fuel', () => {
  it('full-to-full mpg with partial fills', () => {
    const iv = fuelIntervals([fill(1000, 10), fill(1100, 5, 4, false), fill(1280, 10)]);
    expect(iv).toHaveLength(1);
    expect(iv[0].miles).toBe(280); expect(iv[0].mpg).toBeCloseTo(280 / 15, 6); expect(iv[0].costPerMile).toBeCloseTo(60 / 280, 6);
  });
  it('summary and ownership cost', () => {
    const fills = [fill(1000, 10, 4), fill(1200, 14, 5)];
    expect(fuelSummary(fills)).toMatchObject({ fills: 2, gallons: 24, spend: 110, miles: 200 });
    expect(fuelSummary(fills).avgMpg).toBeCloseTo(200 / 14, 6);
    expect(fuelSummary([]).avgMpg).toBeNull();
    const o = ownershipCost(fills, [{ id: 's', date: 'd', title: 'Oil', notes: '', cost: '$120.50' }], [{ id: 'm', date: 'd', title: 'Tune', notes: '', cost: '1,000' }, { id: 'n', date: 'd', title: 'x', notes: '', cost: 'free' }]);
    expect(o).toMatchObject({ fuel: 110, service: 120.5, mods: 1000, total: 1230.5, miles: 200 });
    expect(o.perMile).toBeCloseTo(1230.5 / 200, 6);
    expect(parseMoney(undefined)).toBe(0);
  });
});

describe('quiz', () => {
  const qs = buildQuestions(3);
  const bySource = new Map(collectSourced(Object.values(collections)).map((s) => [s.source, s.confidence]));
  it('only uses confirmed/reported facts and has a valid answer', () => {
    expect(qs.length).toBeGreaterThan(20);
    for (const q of qs) {
      expect(['confirmed', 'reported']).toContain(q.confidence);
      expect(bySource.has(q.source)).toBe(true);
      expect(q.choices[q.answer]).toBeDefined();
      expect(new Set(q.choices).size).toBe(q.choices.length);
      expect(q.choices.length).toBeGreaterThanOrEqual(3);
    }
    expect(qs.find((q) => q.id === 'spec-hp')!.choices[qs.find((q) => q.id === 'spec-hp')!.answer]).toBe('760 hp @ 7,300 rpm');
    expect(qs.some((q) => q.id === 'code-wimbledon-white')).toBe(false);
    expect(qs.some((q) => q.id.startsWith('spec-curb'))).toBe(false); // conflicting values are not quizzed
  });
  it('is deterministic and scores', () => {
    expect(quizRound(5).map((q) => q.id)).toEqual(quizRound(5).map((q) => q.id));
    expect(quizRound(5, 10)).toHaveLength(10);
    const r = rng(1); expect(r()).toBeGreaterThanOrEqual(0);
    let s = recordAnswer(EMPTY_SCORE, true); s = recordAnswer(s, true); s = recordAnswer(s, false);
    expect(s).toEqual({ answered: 3, correct: 2, streak: 0, bestStreak: 2 });
    expect(normScore({ answered: 1, correct: 5 })).toEqual(EMPTY_SCORE);
    expect(normScore('x')).toEqual(EMPTY_SCORE);
  });
});

describe('paint visualizer', () => {
  it('ranks only colors with a sourced count', () => {
    expect(paintInfo('race-red')).toMatchObject({ rank: 1, rankOf: 6 });
    expect(paintInfo('race-red')!.count!.value).toBe(298);
    expect(paintInfo('grabber-lime')!.rank).toBe(2);
    expect(paintInfo('performance-blue')!.rank).toBe(6);
    expect(paintInfo('code-orange')).toMatchObject({ count: null, rank: null });
    expect(paintInfo('nope')).toBeNull();
    expect(paintsFor(2021).every((c) => c.years.includes(2021))).toBe(true);
    expect(paintsFor('all')).toHaveLength(colors.length);
    expect(stripeFor('#f7f7f4')).toBe('#16181c'); expect(stripeFor('#111214')).toBe('#f4f4f4');
  });
});

describe('backup schema 2', () => {
  it('migrates v1 and round-trips v2 stores', () => {
    expect(migrate({ schema: 1 })).toMatchObject({ schema: 9, drag: [], fuel: [], dyno: [] });
    const v1 = validateBackup({ app: 'gt500-companion', schema: 1, garage: {}, plans: [], track: [] });
    expect(v1.ok && v1.migratedFrom).toBe(1);
    const b = makeBackup(EMPTY_GARAGE, [], [], [slip({ id: 'x', quarterEt: 11 })], [fill(10, 5)], { units: 'metric', theme: 'light', lang: 'en' });
    expect(b.schema).toBe(SCHEMA_VERSION);
    const r = parseBackup(JSON.stringify(b));
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.data.drag[0].quarterEt).toBe(11); expect(r.data.fuel[0].gallons).toBe(5); expect(r.data.settings.units).toBe('metric'); expect(r.migratedFrom).toBeNull(); }
  });
  it('rejects non-string rendered fields (regression: crash on import)', () => {
    const base = { app: 'gt500-companion', schema: 2, garage: {}, plans: [], track: [], drag: [], fuel: [], settings: {} };
    const t = { id: 'a', date: 'd', track: 'x', laps: '', pressures: {} };
    for (const bad of [{ ...t, notes: {} }, { ...t, conditions: [] }, { ...t, airTemp: 5 }, { ...t, pressures: { fl: {} } }])
      expect(validateBackup({ ...base, track: [bad] }).ok).toBe(false);
    expect(validateBackup({ ...base, garage: { mods: [{ id: 'm', date: 'd', title: 't', notes: [] }] } }).ok).toBe(false);
    expect(validateBackup({ ...base, garage: { service: [{ id: 'm', date: 'd', title: 't', cost: 5 }] } }).ok).toBe(false);
    expect(validateBackup({ ...base, garage: { nickname: {} } }).ok).toBe(false);
    expect(validateBackup({ ...base, drag: [{ id: 'a', date: 'd', notes: {} }] }).ok).toBe(false);
    expect(validateBackup({ ...base, fuel: [{ id: 'a', date: 'd', odometer: '1', gallons: 1, price: 1, fuel: '93', full: true }] }).ok).toBe(false);
    expect(validateBackup({ ...base, plans: [{ id: 'p', name: 'n', modIds: [], created: 1 }] }).ok).toBe(false);
  });
  it('drops unknown keys', () => {
    const r = validateBackup({ app: 'gt500-companion', schema: 2, garage: { evil: 1 }, plans: [], track: [{ id: 'a', date: 'd', track: 'x', laps: '', pressures: {}, extra: 'x' }], drag: [], fuel: [], settings: {} });
    expect(r.ok).toBe(true);
    if (r.ok) { expect('evil' in r.data.cars.cars[0]).toBe(false); expect('extra' in r.data.track[0]).toBe(false); }
  });
  it('rejects oversized imports', () => {
    const r = parseBackup(' '.repeat(MAX_IMPORT_BYTES + 1));
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors[0]).toMatch(/larger/);
  });
});

describe('stored-data normalizers (regression: corrupt localStorage)', () => {
  it('falls back instead of crashing', () => {
    expect(normGarage({ mods: 5 })).toBeNull();
    expect(normGarage({ mods: null })!.mods).toEqual([]);
    expect(normGarage({ vin: 'X' })!.reminders.length).toBeGreaterThan(0);
    expect(normTrack({})).toBeNull();
    expect(normSlip({ id: 'a', date: 'd', mods: [1] })).toBeNull();
    expect(normSlip({ id: 'a', date: 'd' })!.weather.pressureIsStation).toBe(false);
  });
  it('loaders return defaults for wrong shapes', async () => {
    const store = new Map<string, string>([['gt500.track.v1', '{}'], ['gt500.garage.v1', '{"mods":null}'], ['gt500.drag.v1', '[{"id":1}]'], ['gt500.fuel.v1', '"x"']]);
    vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
    const g = await import('../src/lib/garage');
    const d = await import('../src/lib/drag');
    const f = await import('../src/lib/fuel');
    expect(g.loadTrack()).toEqual([]); expect(g.loadGarage().mods).toEqual([]); expect(d.loadDrag()).toEqual([]); expect(f.loadFuel()).toEqual([]);
    vi.unstubAllGlobals();
  });
});

describe('save failures are reported (regression: silent quota errors)', () => {
  afterEach(() => vi.unstubAllGlobals());
  it('returns false and notifies', async () => {
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: () => { throw new Error('QuotaExceeded'); }, removeItem: () => undefined });
    const { save, onSaveError } = await import('../src/lib/storage');
    const seen: string[] = [];
    const off = onSaveError((k) => seen.push(k));
    expect(save('k', 1)).toBe(false);
    off();
    expect(seen).toEqual(['k']);
  });
});

describe('review regressions', () => {
  it('today() uses the local date', () => {
    expect(today(new Date(2026, 0, 31, 23, 30))).toBe('2026-01-31');
  });
  it('formatLapTime carries rounding into the minute', () => {
    expect(formatLapTime(59.9996)).toBe('1:00.000');
    expect(formatLapTime(119.9999)).toBe('2:00.000');
    expect(formatLapTime(93.84)).toBe('1:33.840');
  });
  it('share card text is truncated to fit', () => {
    const m = (s: string) => s.length * 10;
    expect(fitText('short', 100, m)).toBe('short');
    const t = fitText('a very long track name that will not fit', 100, m);
    expect(m(t)).toBeLessThanOrEqual(100); expect(t.endsWith('…')).toBe(true);
  });
  it('YouTube ids are validated', () => {
    expect(media.every((v) => isYouTubeId(v.youtubeId))).toBe(true);
    expect(isYouTubeId('abc"><script>')).toBe(false);
  });
  it('every data URL is https', () => {
    for (const s of collectSourced(Object.values(collections))) expect(s.source, s.source).toMatch(/^https:\/\//);
  });
});

describe('round 4 data', () => {
  it('redline is reported, rear tire reported', () => {
    expect(specs.find((s) => s.id === 'redline')!.confidence).toBe('reported');
    expect(specs.find((s) => s.id === 'tire-r')!.confidence).toBe('reported');
  });
  it('recall applicability', () => {
    const a = (c: string) => recalls.find((r) => r.campaign === c)!.appliesToGT500;
    expect(a('20V573000')).toBe('yes'); expect(a('23V727000')).toBe('likely');
    expect(a('23V070000')).toBe('no'); expect(a('22V382000')).toBe('no');
    const nhtsa = recalls.filter((r) => r.kind === 'nhtsa-recall');
    expect(nhtsa.length).toBe(16);
    expect(nhtsa.filter((r) => r.appliesToGT500 === 'vin').length).toBe(12);
    expect(nhtsa.every((r) => r.evidence && r.source.startsWith('https://static.nhtsa.gov/'))).toBe(true);
    expect(recalls.find((r) => r.campaign === '20V573000')!.buildWindow).toBe('Feb 28 2019-Aug 13 2020');
    expect(recalls.find((r) => r.id === 'tensioner')!.campaign).toBe('CSP 21B26');
    expect(recalls.find((r) => r.id === 'c105')!.campaign).toBe('SSM 49440');
  });
  it('supplement fluids are reported; intervals unverified; paint codes (round 5)', () => {
    const m = (id: string) => maintenance.find((x) => x.id === id)!;
    expect(String(m('coolant').value)).toContain('VC-13DL-G'); expect(String(m('coolant').value)).toContain('15.2 qt');
    expect(String(m('ic-coolant').value)).toContain('2.5 qt');
    expect(String(m('brake-fluid').value)).toContain('WSS-M6C65-A2');
    expect(String(m('plugs').value)).toContain('0.037'); expect(m('plugs').conflicts!.some((c) => c.confidence === 'unverified')).toBe(true);
    expect(String(m('oil-spec-supp').value)).toContain('WSS-M2C931-C');
    for (const id of ['coolant', 'ic-coolant', 'brake-fluid', 'plugs', 'oil-spec-supp']) { expect(m(id).confidence).toBe('reported'); expect(m(id).note).toMatch(/2021/); }
    expect(m('supp-intervals').confidence).toBe('reported'); expect(String(m('supp-intervals').value)).toContain('spark plugs 100k');
    expect(colors.find((c) => c.id === 'wimbledon-white')!.code).toBe('N4'); // round 7: unverified for 2020–22
    expect(['dark-matter-gray', 'eruption-green', 'brittany-blue'].map((id) => colors.find((c) => c.id === id)!.code)).toEqual(['HY', 'FA', 'EB']);
  });
});

describe('service worker update flow', () => {
  it('waits for a new worker and reloads after SKIP_WAITING', () => {
    _resetForTests();
    let found: () => void = () => undefined;
    let state: () => void = () => undefined;
    const posted: unknown[] = [];
    const worker = { state: 'installing', addEventListener: (_: string, f: () => void) => { state = f; }, postMessage: (m: unknown) => posted.push(m) } as unknown as ServiceWorker;
    const reg: RegLike = { waiting: null, installing: worker, addEventListener: (_t, f) => { found = f; } };
    const seen: boolean[] = [];
    onUpdateReady((w) => seen.push(w));
    watchRegistration(reg, () => true);
    found();
    (worker as unknown as { state: string }).state = 'installed'; state();
    expect(seen).toEqual([false, true]);
    let onCtl: () => void = () => undefined;
    let reloaded = 0;
    expect(applyUpdate({ addEventListener: (_: string, f: () => void) => { onCtl = f; } } as never, () => reloaded++)).toBe(true);
    expect(posted).toEqual([{ type: 'SKIP_WAITING' }]);
    onCtl(); onCtl();
    expect(reloaded).toBe(1);
  });
  it('first install (no controller) is not an update', () => {
    _resetForTests();
    const w = {} as ServiceWorker;
    const seen: boolean[] = [];
    onUpdateReady((x) => seen.push(x));
    watchRegistration({ waiting: w, installing: null, addEventListener: () => undefined }, () => false);
    expect(seen).toEqual([false]);
    expect(applyUpdate(undefined)).toBe(false);
  });
});
