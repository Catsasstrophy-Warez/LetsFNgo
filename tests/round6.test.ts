import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { convertCorrection, dryPressureHpa, parseCurve, peaks, saeFactor, stdFactor, type DynoPull } from '../src/lib/dyno';
import { normDyno, normNotify } from '../src/lib/validate';
import { MAX_SHARE_CHARS, decodeShare, encodeShare, shareUrl } from '../src/lib/share';
import { compareTires, revsPerMile, tireInfo } from '../src/lib/tires';
import { GT500_FINAL, GT500_RATIOS, GT500_REDLINE, mphAt } from '../src/lib/gearing';
import { costPerHp } from '../src/lib/roi';
import { modStages } from '../src/data/mods';
import { DASH_IDS, loadDash, moveCard, normDashboard, toggleCard } from '../src/lib/dashboard';
import { dueAlerts } from '../src/lib/notify';
import { DEFAULT_REMINDERS, EMPTY_GARAGE } from '../src/lib/garage';
import { SCHEMA_VERSION, makeBackup, migrate, validateBackup } from '../src/lib/backup';
import { dynoBaselines, DYNO_CAVEAT } from '../src/data/dyno';
import { maintenance } from '../src/data/maintenance';
import { production } from '../src/data/production';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k) });
afterAll(() => vi.unstubAllGlobals());
beforeEach(() => store.clear());

const W = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
const pull = (o: Partial<DynoPull> = {}): DynoPull => ({ id: 'p', date: '2026-05-01', shop: 'X', whp: 680, wtq: 590, dynoType: 'dynojet', correction: 'sae', weather: W, mods: [], curve: [], notes: '', ...o });

describe('dyno corrections', () => {
  it('SAE J1349 is 1.000 at its reference (25 °C, 99 kPa dry)', () => {
    expect(saeFactor({ tempF: 77, pressureInHg: 990 / 33.8638866667, humidity: 0, pressureIsStation: true })!).toBeCloseTo(1, 4);
  });
  it('STD (J607) is 1.000 at 60 °F, 29.92 inHg dry', () => {
    expect(stdFactor({ tempF: 60, pressureInHg: 29.92, humidity: 0, pressureIsStation: true })!).toBeCloseTo(1, 4);
  });
  it('hot, thin air raises both factors; STD ≈ 4% above SAE in typical weather', () => {
    const a = { tempF: 90, pressureInHg: 29.0, humidity: 40, pressureIsStation: true };
    expect(saeFactor(a)!).toBeGreaterThan(1.03);
    const std = convertCorrection(700, 'sae', 'std', a)!;
    expect(std / 700).toBeGreaterThan(1.03); expect(std / 700).toBeLessThan(1.06);
    expect(convertCorrection(std, 'std', 'sae', a)!).toBeCloseTo(700, 6);
    expect(convertCorrection(700, 'uncorrected', 'sae', a)!).toBeCloseTo(700 * saeFactor(a)!, 6);
  });
  it('humidity lowers dry pressure; elevation converts a corrected barometer', () => {
    const dry = dryPressureHpa({ tempF: 80, pressureInHg: 29.92, humidity: 0, pressureIsStation: true })!;
    expect(dryPressureHpa({ tempF: 80, pressureInHg: 29.92, humidity: 100, pressureIsStation: true })!).toBeLessThan(dry - 30);
    expect(dryPressureHpa({ tempF: 80, pressureInHg: 29.92, humidity: 0, elevationFt: 5000 })!).toBeLessThan(dry * 0.85);
  });
  it('refuses incomplete or impossible weather', () => {
    expect(convertCorrection(700, 'sae', 'std', null)).toBeNull();
    expect(saeFactor({ tempF: 70, pressureInHg: 0, humidity: 0 })).toBeNull();
    expect(saeFactor({ tempF: 70, pressureInHg: 29, humidity: 140 })).toBeNull();
    expect(convertCorrection(700, 'sae', 'sae', null)).toBe(700);
  });
});

describe('dyno curves and validation', () => {
  it('parses rpm/hp/tq rows in any separator and sorts', () => {
    const r = parseCurve('rpm,hp,tq\n7000, 690, 518\n3000\t280\t490\n5000 520 -');
    expect(r.ok && r.points.map((p) => p.rpm)).toEqual([3000, 5000, 7000]);
    expect(r.ok && r.points[1].tq).toBeNull();
  });
  it('rejects bad rows', () => {
    expect(parseCurve('abc').ok).toBe(true); // header-only = empty
    expect(parseCurve('20000, 1, 1').ok).toBe(false);
    expect(parseCurve('5000, -3, 1').ok).toBe(false);
    expect(parseCurve('5000, -, -').ok).toBe(false);
    expect(parseCurve(Array(401).fill('5000, 1, 1').join('\n')).ok).toBe(false);
  });
  it('peaks come from the curve when it is higher', () => {
    expect(peaks(pull({ curve: [{ rpm: 7000, hp: 700, tq: 500 }, { rpm: 4000, hp: 400, tq: 600 }] }))).toEqual({ hp: 700, tq: 600 });
  });
  it('normDyno allow-lists enums and ranges', () => {
    expect(normDyno(pull())).toEqual(pull());
    expect(normDyno({ ...pull(), dynoType: 'chassis' })).toBeNull();
    expect(normDyno({ ...pull(), correction: 'DIN' })).toBeNull();
    expect(normDyno({ ...pull(), whp: 0 })).toBeNull();
    expect(normDyno({ ...pull(), whp: '700' })).toBeNull();
    expect(normDyno({ ...pull(), curve: [{ rpm: 'x' }] })).toBeNull();
    expect(normDyno({ ...pull(), curve: Array(401).fill({ rpm: 1, hp: 1, tq: 1 }) })).toBeNull();
    expect(normDyno({ ...pull(), weather: { humidity: 300 } })).toBeNull();
    expect(normDyno({ ...pull(), extra: '<script>' })).not.toHaveProperty('extra');
  });
  it('sourced stock baselines carry source, confidence and a caveat', () => {
    expect(dynoBaselines.map((b) => b.whp).sort()).toEqual([664, 668, 684, 708, 723]);
    for (const b of dynoBaselines) { expect(b.source).toMatch(/^https:\/\//); expect(['confirmed', 'reported', 'unverified']).toContain(b.confidence); }
    expect(dynoBaselines.find((b) => b.id === 'barrett')!.confidence).toBe('unverified');
    expect(dynoBaselines.find((b) => b.id === 'lmr')!.wtq).toBe(560);
    expect(DYNO_CAVEAT).toMatch(/dyno type/);
  });
});

describe('share links', () => {
  it('round-trips a plan and a car', () => {
    const p = encodeShare({ v: 1, k: 'plan', name: 'Big ✓', modIds: ['vmp', 'tune', 'nope'] })!;
    expect(decodeShare(p)).toEqual({ ok: true, data: { v: 1, k: 'plan', name: 'Big ✓', modIds: ['vmp', 'tune'] } });
    const c = encodeShare({ v: 1, k: 'car', year: '2021', color: 'race-red', nickname: 'Snake', mods: ['Tune', ''] })!;
    expect(decodeShare(c)).toEqual({ ok: true, data: { v: 1, k: 'car', year: '2021', color: 'race-red', nickname: 'Snake', mods: ['Tune'] } });
    expect(shareUrl(c, { origin: 'https://h', pathname: '/sub/' })).toBe(`https://h/sub/#/share/${c}`);
  });
  const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  it('rejects damaged, oversized, unknown and hostile payloads', () => {
    expect(decodeShare('').ok).toBe(false);
    expect(decodeShare('a'.repeat(MAX_SHARE_CHARS + 1)).ok).toBe(false);
    expect(decodeShare('abc$%').ok).toBe(false);
    expect(decodeShare('!!!').ok).toBe(false);
    expect(decodeShare('YWJj').ok).toBe(false); // "abc" — not JSON
    expect(decodeShare(enc([1, 2])).ok).toBe(false);
    expect(decodeShare(enc({ v: 2, k: 'plan', name: 'x', modIds: [] }))).toMatchObject({ ok: false, error: /newer/ });
    expect(decodeShare(enc({ v: 1, k: 'plan', name: 'x', modIds: ['__proto__'] })).ok).toBe(false);
    expect(decodeShare(enc({ v: 1, k: 'plan', name: { a: 1 }, modIds: [] })).ok).toBe(false);
    expect(decodeShare(enc({ v: 1, k: 'car', year: '1999', color: '', nickname: '', mods: [] })).ok).toBe(false);
    expect(decodeShare(enc({ v: 1, k: 'car', year: '', color: 'javascript:alert(1)', nickname: '', mods: [] })).ok).toBe(false);
    expect(decodeShare(enc({ v: 1, k: 'car', year: '', color: '', nickname: '', mods: [5] })).ok).toBe(false);
    expect(decodeShare(enc({ v: 1, k: 'vin', vin: 'x' })).ok).toBe(false);
  });
  it('caps size on encode', () => {
    expect(encodeShare({ v: 1, k: 'car', year: '', color: '', nickname: 'n', mods: Array(100).fill('x'.repeat(200)) })).toBeNull();
  });
});

describe('tire calculator', () => {
  it('diameter, revs/mile and speedo error', () => {
    const t = tireInfo('315/30R20')!;
    expect(t.diameterIn).toBeCloseTo(27.44, 2);
    expect(revsPerMile(t.diameterIn)).toBeCloseTo(735, 0);
    const c = compareTires('315/30R20', '315/35R20', GT500_RATIOS, GT500_FINAL, GT500_REDLINE)!;
    expect(c.diameterPct).toBeCloseTo(4.52, 1);
    expect(c.actualAt(60)).toBeCloseTo(62.7, 1);
    expect(c.effectiveFinal).toBeLessThan(GT500_FINAL);
    expect(c.topSpeedPerGear[0].stock).toBeCloseTo(mphAt(GT500_REDLINE, GT500_RATIOS[0], GT500_FINAL, t.diameterIn), 6);
    expect(c.rpmAt(60, GT500_RATIOS[5]).alt).toBeLessThan(c.rpmAt(60, GT500_RATIOS[5]).stock);
  });
  it('same tire → no error; invalid sizes → null', () => {
    expect(compareTires('315/30R20', '315/30ZR20', GT500_RATIOS, 3.73, 7500)!.speedoErrorPct).toBeCloseTo(0, 9);
    expect(compareTires('315/30R20', 'big', GT500_RATIOS, 3.73, 7500)).toBeNull();
  });
});

describe('cost per hp', () => {
  it('uses only sourced gain + price; else insufficient data', () => {
    const rows = costPerHp(modStages.filter((m) => ['tune', 'whipple', 'borla'].includes(m.id)));
    expect(rows.every((r) => !r.ok)).toBe(true);
    expect(rows.find((r) => r.mod.id === 'tune')!).toMatchObject({ ok: false, missing: ['price'] });
    expect(rows.find((r) => r.mod.id === 'borla')!).toMatchObject({ ok: false, missing: ['gain'] });
    const fake = costPerHp([{ ...modStages[0], cost: { min: 1000, max: 1200 }, gain: { whp: 50, basis: 't' } }])[0];
    expect(fake).toMatchObject({ ok: true, perHpMin: 20, perHpMax: 24 });
  });
});

describe('dashboard layout', () => {
  it('moves, hides and normalizes', () => {
    const d = loadDash();
    expect(d.order).toEqual([...DASH_IDS]);
    expect(moveCard(d, 'tools', -1).order.indexOf('tools')).toBe(1);
    expect(moveCard(d, 'garage', -1)).toBe(d);
    expect(toggleCard(toggleCard(d, 'legend'), 'legend').hidden).toEqual([]);
    expect(normDashboard({ order: ['tools', 'bogus', 'tools'], hidden: ['x', 'legend'] })).toEqual({ order: ['tools', ...DASH_IDS.filter((x) => x !== 'tools')], hidden: ['legend'] });
    expect(normDashboard({ order: [1], hidden: [] })).toBeNull();
    store.set('gt500.home.v1', '{"order":"nope"}');
    expect(loadDash().order).toEqual([...DASH_IDS]);
  });
});

describe('maintenance notifications', () => {
  const r = { id: 'r1', item: 'Oil', everyMiles: 10000, everyMonths: 12, lastMiles: 1000, lastDate: '2025-01-15' };
  it('alerts due/overdue reminders once per due point', () => {
    const a = dueAlerts([r], 10800, '2025-06-01', {});
    expect(a).toHaveLength(1); expect(a[0].title).toBe('Due soon: Oil');
    expect(dueAlerts([r], 10800, '2025-06-01', { r1: a[0].key })).toHaveLength(0);
    const o = dueAlerts([r], 11200, '2025-06-01', { r1: a[0].key });
    expect(o[0].title).toMatch(/^Overdue/);
    expect(dueAlerts([r], 2000, '2025-06-01', {})).toHaveLength(0);
    expect(dueAlerts([{ ...r, lastMiles: 11000, lastDate: '2025-06-01' }], 20900, '2025-07-01', { r1: a[0].key })).toHaveLength(1);
  });
  it('normNotify validates', () => {
    expect(normNotify({ enabled: true, sent: { a: 'k' } })).toEqual({ enabled: true, sent: { a: 'k' } });
    expect(normNotify({ enabled: 'yes' })).toBeNull();
    expect(normNotify({ enabled: true, sent: { a: 1 } })).toBeNull();
  });
});

describe('backup schema 4', () => {
  it('round-trips new stores and migrates v3', () => {
    expect(SCHEMA_VERSION).toBe(6);
    const b = JSON.parse(JSON.stringify(makeBackup(EMPTY_GARAGE, [], [], [], [], undefined, 'x', undefined, { dyno: [pull({ curve: [{ rpm: 5000, hp: 500, tq: 520 }] })], notify: { enabled: true, sent: {} }, dashboard: { order: ['tools', ...DASH_IDS.filter((x) => x !== 'tools')], hidden: ['legend'] } })));
    const r = validateBackup(b);
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.data.dyno[0].curve[0].hp).toBe(500); expect(r.data.notify.enabled).toBe(true); expect(r.data.dashboard.hidden).toEqual(['legend']); }
    const { dyno: _d, notify: _n, dashboard: _b, ...v3 } = b; void _d; void _n; void _b;
    const m = validateBackup({ ...v3, schema: 3 });
    expect(m.ok && m.migratedFrom).toBe(3);
    if (m.ok) { expect(m.data.dyno).toEqual([]); expect(m.data.notify.enabled).toBe(false); expect(m.data.dashboard.order).toEqual([...DASH_IDS]); }
    expect(migrate({ schema: 3 })).toMatchObject({ schema: 6, dyno: [] });
    expect(validateBackup({ ...b, dyno: [{ ...pull(), whp: -1 }] }).ok).toBe(false);
    expect(validateBackup({ ...b, notify: { enabled: 1 } }).ok).toBe(false);
  });
});

describe('round 5 research integration', () => {
  it('reminder defaults follow the 2021 supplement', () => {
    const by = (id: string) => DEFAULT_REMINDERS.find((r) => r.id === id)!;
    expect(by('r-oil')).toMatchObject({ everyMiles: 10000, everyMonths: 12 });
    expect(by('r-brake').everyMonths).toBe(36);
    expect(by('r-plugs').everyMiles).toBe(100000);
    expect(by('r-diff').everyMiles).toBe(150000);
    expect(by('r-coolant')).toMatchObject({ everyMiles: 200000, everyMonths: 120 });
    expect(String(maintenance.find((m) => m.id === 'track-intervals')!.value)).toMatch(/500 mi.*DOT 4 LV/);
    expect(production.find((p) => p.id === 'total')!.confidence).toBe('unverified');
  });
});
