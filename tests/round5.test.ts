import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { bestLap, clock, currentLap, elapsed, lap, lapsToText, newWatch, pause, start } from '../src/lib/timer';
import { parseLaps } from '../src/lib/laptime';
import { MPH, QUARTER_M, accuracyState, analyzeRun, cumulative, haversine, speeds, syntheticTrace, type Fix } from '../src/lib/gps';
import { checkPlan, dctRatingLow, fuelParts, orderOfOps, quotedTorque } from '../src/lib/compat';
import { modStages } from '../src/data/mods';
import { buildTimeline, filterTimeline, yearlySummary } from '../src/lib/timeline';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { colorRows, headToHead, packageRows, priceGrid, rivals } from '../src/lib/yearDiff';
import { colors } from '../src/data/colors';
import { prices } from '../src/data/pricing';
import { SCHEMA_VERSION, makeBackup, migrate, validateBackup } from '../src/lib/backup';
import { normSlip } from '../src/lib/validate';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
afterAll(() => vi.unstubAllGlobals());
beforeEach(() => store.clear());

const mod = (id: string) => modStages.find((m) => m.id === id)!;

describe('session timer', () => {
  it('starts, pauses, resumes and splits laps', () => {
    let w = start(newWatch(), 1000);
    expect(elapsed(w, 3500)).toBe(2500);
    w = lap(w, 91_000); // 90 s lap
    w = lap(w, 91_300); // double tap ignored (<1 s)
    expect(w.laps).toEqual([90_000]);
    w = pause(w, 100_000);
    expect(elapsed(w, 999_999)).toBe(99_000);
    expect(lap(w, 200_000)).toBe(w); // stopped: no lap
    w = start(w, 200_000);
    expect(currentLap(w, 200_000 + 1000)).toBe(10_000);
    w = lap(w, 286_500);
    expect(w.laps).toEqual([90_000, 95_500]);
    expect(bestLap(w.laps)).toBe(90_000);
    expect(bestLap([])).toBeNull();
  });
  it('writes Track-log text that parseLaps reads back', () => {
    const txt = lapsToText([95_214, 61_000.4]);
    expect(txt).toBe('1:35.214\n1:01.000');
    expect(parseLaps(txt).laps.map((l) => l.time)).toEqual([95.214, 61]);
  });
  it('formats the clock', () => {
    expect(clock(0)).toBe('0:00.00');
    expect(clock(65_430)).toBe('1:05.43');
    expect(clock(3_725_010)).toBe('1:02:05.01');
  });
});

describe('GPS meter math (synthetic traces)', () => {
  // 60 mph in 3.5 s → a = 26.8224 / 3.5
  const a60 = (60 * MPH) / 3.5;
  it('haversine ≈ 111.2 km per degree of latitude', () => {
    expect(haversine({ lat: 0, lon: 0 }, { lat: 1, lon: 0 })).toBeCloseTo(111195, -2);
  });
  it('times 0–60 from Doppler speed', () => {
    const r = analyzeRun('0-60', syntheticTrace({ accelMps2: a60, seconds: 6, hz: 5 }));
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.seconds).toBeCloseTo(3.5, 1); expect(r.worstAccuracyM).toBe(3); }
  });
  it('times 0–60 from positions only (no Doppler speed)', () => {
    const r = analyzeRun('0-60', syntheticTrace({ accelMps2: a60, seconds: 6, hz: 10, useSpeed: false }));
    expect(r.ok).toBe(true);
    if (r.ok) expect(Math.abs(r.seconds - 3.5)).toBeLessThan(0.15);
  });
  it('times 60–130 from a rolling start', () => {
    // 50 mph → constant 6 m/s²; 60→130 takes 70 mph / 6 m/s² ≈ 5.2156 s
    const tr = syntheticTrace({ accelMps2: 6, seconds: 12, hz: 5, v0: 50 * MPH, idle: 0 });
    const r = analyzeRun('60-130', tr);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.seconds).toBeCloseTo((70 * MPH) / 6, 1);
  });
  it('times a ¼ mile with trap speed', () => {
    const acc = 7; // m/s² → t = sqrt(2d/a)
    const r = analyzeRun('quarter', syntheticTrace({ accelMps2: acc, seconds: 14, hz: 5 }));
    const t = Math.sqrt((2 * QUARTER_M) / acc);
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.seconds).toBeCloseTo(t, 1); expect(r.trapMph!).toBeCloseTo((acc * t) / MPH, 0); }
  });
  it('refuses poor accuracy', () => {
    const tr = syntheticTrace({ accelMps2: a60, seconds: 6, hz: 5 }).map((f, i) => (i === 12 ? { ...f, accuracy: 25 } : f));
    const r = analyzeRun('0-60', tr);
    expect(r.ok).toBe(false);
    if (!r.ok) { expect(r.final).toBe(true); expect(r.reason).toMatch(/accuracy too poor/); }
  });
  it('refuses sparse fixes and unfinished runs', () => {
    const tr = syntheticTrace({ accelMps2: a60, seconds: 6, hz: 5 }).filter((_, i) => i < 8 || i > 20);
    expect(analyzeRun('0-60', tr)).toMatchObject({ ok: false, final: true });
    expect(analyzeRun('0-60', syntheticTrace({ accelMps2: 2, seconds: 5 }))).toMatchObject({ ok: false, reason: '60 mph was not reached.' });
    expect(analyzeRun('quarter', syntheticTrace({ accelMps2: 7, seconds: 5 }))).toMatchObject({ ok: false });
    expect(analyzeRun('0-60', [])).toMatchObject({ ok: false });
    // never launched from a stop
    expect(analyzeRun('0-60', syntheticTrace({ accelMps2: 3, seconds: 10, v0: 10, idle: 0 }))).toMatchObject({ ok: false, reason: 'No launch from a stop was detected.' });
  });
  it('speeds, cumulative and accuracy state', () => {
    const fx: Fix[] = [{ t: 0, lat: 0, lon: 0, accuracy: 5, speed: null }, { t: 1000, lat: 0.0001, lon: 0, accuracy: 5, speed: null }];
    expect(speeds(fx)[1]).toBeCloseTo(11.12, 1);
    expect(cumulative(fx)[1]).toBeCloseTo(11.12, 1);
    expect(accuracyState(null)).toBe('none'); expect(accuracyState(4)).toBe('ok'); expect(accuracyState(30)).toBe('poor');
  });
});

describe('mod compatibility rules', () => {
  it('reads sourced torque figures and the DCT rating', () => {
    expect(dctRatingLow()).toBe(664);
    expect(quotedTorque(mod('hpj'))).toEqual([869]);
    expect(quotedTorque(mod('vmp'))).toEqual([718]);
    expect(quotedTorque(mod('tune'))).toEqual([]);
  });
  it('warns on DCT torque, E85 fuel parts, two blowers and race fuel', () => {
    const w = checkPlan([mod('vmp'), mod('hpj'), mod('lund-villain')]);
    const ids = w.map((x) => x.id);
    expect(ids).toEqual(['dct-torque', 'e85-fuel', 'one-blower', 'race-fuel']);
    expect(w[0].basis[0].confidence).toBe('unverified');
    expect(w[1].text).toContain('ID1300x injectors');
    expect(fuelParts(mod('vmp'))).toEqual(['larger injectors', 'pump voltage booster']);
    for (const x of w) for (const b of x.basis) expect(b.source).toMatch(/^https:\/\//);
  });
  it('is quiet for unrelated mods and orders by sourced stage', () => {
    expect(checkPlan([mod('tune'), mod('borla')])).toEqual([]);
    expect(orderOfOps([mod('borla'), mod('whipple'), mod('tune')]).map((m) => m.id)).toEqual(['tune', 'whipple', 'borla']);
  });
});

describe('ownership timeline', () => {
  const g = { ...EMPTY_GARAGE, service: [{ id: 's', date: '2025-03-01', title: 'Oil', notes: '', miles: '3000', cost: '$150' }], mods: [{ id: 'm', date: '2026-01-10', title: 'Tune', notes: '', cost: '900' }, { id: 'x', date: '', title: 'undated', notes: '' }] };
  const track = [{ id: 't', date: '2026-02-01', track: 'Laguna Seca', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: '1:40.0\n1:39.5', notes: '' }];
  const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
  const drag = [{ id: 'd', date: '2026-03-01', track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null, weather: w, mods: [], notes: '', gps: { kind: '0-60' as const, seconds: 3.6, trapMph: null, accuracyM: 3 } }];
  const fuel = [{ id: 'f', date: '2026-01-05', odometer: 1000, gallons: 10, price: 4.5, fuel: '93' as const, blend: null, full: true, notes: '' }];
  it('merges, sorts newest first and skips undated', () => {
    const ev = buildTimeline(g, track, drag, fuel);
    expect(ev.map((e) => e.kind)).toEqual(['drag', 'track', 'mod', 'fuel', 'service']);
    expect(ev[0].detail).toContain('GPS estimate');
    expect(ev[1].detail).toContain('2 laps');
    expect(ev.find((e) => e.kind === 'fuel')!.cost).toBe(45);
  });
  it('filters and summarizes by year', () => {
    const ev = buildTimeline(g, track, drag, fuel);
    expect(filterTimeline(ev, ['mod', 'service'], null)).toHaveLength(2);
    expect(filterTimeline(ev, ['mod', 'service', 'fuel', 'track', 'drag'], '2025')).toHaveLength(1);
    const ys = yearlySummary(ev, fuel);
    expect(ys.map((y) => y.year)).toEqual(['2026', '2025']);
    expect(ys[0]).toMatchObject({ spend: 945, modSpend: 900, fuelSpend: 45, gallons: 10 });
    expect(ys[0].counts).toEqual({ service: 0, mod: 1, track: 1, drag: 1, fuel: 1 });
    expect(ys[1].serviceSpend).toBe(150);
  });
});

describe('year diff and head-to-head', () => {
  it('derives color and package presence from data', () => {
    const rows = colorRows();
    expect(rows).toHaveLength(colors.length);
    const lime = rows.find((r) => r.item.id === 'grabber-lime')!;
    expect(lime.years).toEqual({ 2020: true, 2021: false, 2022: false });
    expect(lime.differs).toBe(true);
    const cftp = packageRows().find((r) => r.item.id === 'cftp')!;
    expect(cftp.differs).toBe(false);
    expect(packageRows().some((r) => r.item.id === 'convenience')).toBe(false);
  });
  it('price grid keeps every sourced record including conflicts', () => {
    const msrp = priceGrid().find((r) => r.kind === 'msrp')!;
    expect(msrp.cells[2022].length).toBe(prices.filter((p) => p.kind === 'msrp' && p.year === 2022).length);
    expect(msrp.cells[2022].length).toBeGreaterThanOrEqual(2);
    expect(msrp.cells[2021][0].value).toBe(70300);
  });
  it('head-to-head uses sourced values only and hides unverified sheets by default', () => {
    const h = headToHead('superstock')!;
    expect(h.rows.find((r) => r.label === 'Horsepower')).toMatchObject({ gt500: '760 hp', rival: '807 hp', better: 'rival' });
    expect(h.rows.find((r) => r.label === 'Weight')!.better).toBe('gt500');
    const red = headToHead('redeye')!;
    expect(red.rivalSheet).toBeNull();
    expect(red.rows.find((r) => r.label === '0–60 mph')!.rival).toBeNull();
    expect(headToHead('redeye', true)!.rows.find((r) => r.label === '0–60 mph')!.rival).toBe('3.4 s');
    expect(headToHead('gt500')).toBeNull();
    expect(rivals().some((c) => c.id === 'gt500')).toBe(false);
  });
});

describe('backup schema 3', () => {
  it('migrates v2 with onboarding done and round-trips gps runs', () => {
    expect(SCHEMA_VERSION).toBe(6);
    expect(migrate({ schema: 2 })).toMatchObject({ schema: 6, onboarding: { done: true } });
    expect(migrate({ schema: 1 })).toMatchObject({ schema: 6, drag: [], onboarding: { done: true } });
    const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
    const slip = { id: 'g', date: '2026-01-01', track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null, weather: w, mods: [], notes: 'GPS estimate', gps: { kind: 'quarter', seconds: 11.2, trapMph: 125, accuracyM: 2.5 } };
    const b = JSON.parse(JSON.stringify(makeBackup(EMPTY_GARAGE, [], [], [slip as never], [], undefined, 'x', { done: true, completed: '2026-01-01' })));
    const r = validateBackup(b);
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.data.drag[0].gps).toEqual(slip.gps); expect(r.data.onboarding.done).toBe(true); expect(r.migratedFrom).toBeNull(); }
    const v2 = validateBackup({ ...b, schema: 2, onboarding: undefined });
    expect(v2.ok && v2.migratedFrom).toBe(2);
  });
  it('rejects malformed gps and onboarding', () => {
    const base = { id: 'g', date: 'd', weather: {}, mods: [] };
    expect(normSlip({ ...base, gps: { kind: '0-100', seconds: 3, accuracyM: 3 } })).toBeNull();
    expect(normSlip({ ...base, gps: { kind: '0-60', seconds: -1, accuracyM: 3 } })).toBeNull();
    expect(normSlip({ ...base, gps: { kind: '0-60', seconds: '3', accuracyM: 3 } })).toBeNull();
    expect(normSlip(base)).not.toHaveProperty('gps');
    const bad = validateBackup({ ...makeBackup(EMPTY_GARAGE, [], []), onboarding: { done: 'yes' } });
    expect(bad.ok).toBe(false);
  });
});

describe('onboarding', () => {
  it('first run only, seeds Garage without clobbering', async () => {
    const o = await import('../src/lib/onboarding');
    const { loadGarage, saveGarage } = await import('../src/lib/garage');
    expect(o.needsOnboarding()).toBe(true);
    o.seedGarage({ year: '2021', color: 'carbonized-gray', vin: ' 1fa6p8sj0m5500000 ' });
    expect(loadGarage()).toMatchObject({ year: '2021', color: 'carbonized-gray', vin: '1FA6P8SJ0M5500000' });
    expect(o.needsOnboarding()).toBe(false); // garage has data now
    o.seedGarage({ year: '', color: '', vin: '' });
    expect(loadGarage().year).toBe('2021');
    saveGarage({ ...EMPTY_GARAGE });
    expect(o.needsOnboarding()).toBe(true);
    o.finishOnboarding();
    expect(o.needsOnboarding()).toBe(false);
    expect(o.loadOnboarding().done).toBe(true);
    store.set(o.ONBOARDING_KEY, '{"done":"x"}');
    expect(o.loadOnboarding().done).toBe(false);
  });
});
