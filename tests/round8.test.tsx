import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter, Route, Routes } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { CarContext } from '../src/components/CarContext';
import type { Lang, MsgKey } from '../src/lib/i18n';
import { en, missingKeys, translate } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import {
  DEFAULT_CAR_ID, EMPTY_GARAGE, KEYS, MAX_CARS, activeCar, addCar, carLabel, carOf, forCar, loadCars, loadGarage, removeCarFromStore,
  saveCars, saveGarage, setActiveCar, type CarStore,
} from '../src/lib/garage';
import { normCarStore, normFill, normSlip, normTrack } from '../src/lib/validate';
import { deleteCar, mergeCarList, purgeCarLogs } from '../src/lib/carlog';
import { SCHEMA_VERSION, makeBackup, migrate, parseBackup, restoreBackup, validateBackup } from '../src/lib/backup';
import { CRLF, escapeText, foldLine, icsDate, remindersToIcs } from '../src/lib/ics';
import { buildReport, coversYear, escapeHtml, maskVin, recallChecklist, reportHtml } from '../src/lib/report';
import { DEFAULT_FILTER, byDate, byMileage, dateValue, filterAuctions, median, priced } from '../src/lib/market';
import { auctionResults, marketStats } from '../src/data/auctions';
import { computeAchievements, milesLogged, normAch, unseen } from '../src/lib/achievements';
import { createShortcuts, isTyping, GO } from '../src/lib/shortcuts';
import { dueAlerts } from '../src/lib/notify';
import { colors } from '../src/data/colors';
import { recalls } from '../src/data/recalls';
import type { AuctionResult } from '../src/data/types';
import type { Timeslip } from '../src/lib/drag';
import type { FillUp } from '../src/lib/fuel';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); } });
afterAll(() => vi.unstubAllGlobals());
beforeEach(() => store.clear());

const W = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
const slip = (id: string, date: string, et: number | null, extra: Partial<Timeslip> = {}): Timeslip => ({ id, date, track: 'T', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: et, quarterMph: null, da: null, weather: W, mods: [], notes: '', ...extra });
const fill = (id: string, date: string, odometer: number, carId?: string): FillUp => ({ id, date, odometer, gallons: 10, price: 4, fuel: '93', blend: null, full: true, notes: '', ...(carId ? { carId } : {}) });

describe('multi-car Garage store', () => {
  it('migrates the legacy single-car key losslessly to car #1 without touching it', () => {
    const legacy = { vin: '1FA6P8SJ0L5500000', year: '2020', color: 'race-red', nickname: 'Snake', odometer: '1234', mods: [{ id: 'm', date: '2025-01-01', title: 'Tune', notes: 'n', miles: '10', cost: '900' }], service: [], reminders: [{ id: 'r', item: 'Oil', everyMiles: 5000, everyMonths: 6, lastMiles: 100, lastDate: '2025-01-01' }] };
    store.set(KEYS.garage, JSON.stringify(legacy));
    const s = loadCars();
    expect(s.active).toBe(DEFAULT_CAR_ID);
    expect(s.cars).toEqual([{ ...legacy, id: DEFAULT_CAR_ID }]);
    expect(loadGarage()).toEqual(legacy);
    // Saving writes the new key; the legacy key is left as it was.
    saveGarage({ ...loadGarage(), nickname: 'Eleanor' });
    expect(JSON.parse(store.get(KEYS.cars)!).cars[0].nickname).toBe('Eleanor');
    expect(JSON.parse(store.get(KEYS.garage)!).nickname).toBe('Snake');
    expect(loadGarage().nickname).toBe('Eleanor');
  });
  it('starts with one empty car when nothing is stored; a corrupt cars key falls back to legacy', () => {
    expect(loadCars().cars).toHaveLength(1);
    expect(loadGarage().reminders.length).toBeGreaterThan(0);
    store.set(KEYS.garage, JSON.stringify({ nickname: 'Legacy' }));
    store.set(KEYS.cars, '{not json');
    expect(loadGarage().nickname).toBe('Legacy');
    store.set(KEYS.cars, JSON.stringify({ active: 'x', cars: [] }));
    expect(loadGarage().nickname).toBe('Legacy');
  });
  it('adds, switches, saves only the active car and removes cars (never the last)', () => {
    saveGarage({ ...EMPTY_GARAGE, nickname: 'One' });
    const id = addCar({ nickname: 'Two', year: '2022' })!;
    expect(id).not.toBe(DEFAULT_CAR_ID);
    expect(loadGarage().nickname).toBe('Two');
    expect(loadGarage().reminders).not.toBe(EMPTY_GARAGE.reminders); // fresh copy, not shared
    saveGarage({ ...loadGarage(), odometer: '500' });
    expect(loadCars().cars.find((c) => c.id === DEFAULT_CAR_ID)!.odometer).toBe('');
    expect(setActiveCar(DEFAULT_CAR_ID)).toBe(true);
    expect(loadGarage().nickname).toBe('One');
    expect(setActiveCar('nope')).toBe(false);
    const s = loadCars();
    expect(removeCarFromStore(DEFAULT_CAR_ID, s)!.active).toBe(id);
    expect(removeCarFromStore(id, { active: id, cars: [s.cars[1]] })).toBeNull();
    expect(carLabel({ nickname: ' ', year: '2021' }, 0)).toBe('2021 GT500');
    expect(carLabel({ nickname: '', year: '' }, 2)).toBe('Car 3');
  });
  it('saveGarage never writes a stray id into the car', () => {
    saveGarage({ ...EMPTY_GARAGE, id: 'evil' } as never);
    expect(loadCars().cars[0].id).toBe(DEFAULT_CAR_ID);
  });
  it('enforces the car limit', () => {
    const s: CarStore = { active: 'a0', cars: Array.from({ length: MAX_CARS }, (_, i) => ({ ...EMPTY_GARAGE, id: `a${i}` })) };
    saveCars(s);
    expect(addCar()).toBeNull();
    expect(normCarStore({ ...s, cars: [...s.cars, { ...EMPTY_GARAGE, id: 'z' }] })).toBeNull();
  });
  it('validates the store strictly', () => {
    const ok = { active: 'b', cars: [{ id: 'a' }, { id: 'b', nickname: 'B' }] };
    expect(normCarStore(ok)!.active).toBe('b');
    expect(normCarStore({ ...ok, active: 'zzz' })!.active).toBe('a');
    expect(normCarStore({ active: 'a', cars: [{ id: 'a' }, { id: 'a' }] })).toBeNull(); // duplicate ids
    expect(normCarStore({ active: 'a', cars: [{ id: 'a b' }] })).toBeNull(); // bad id
    expect(normCarStore({ active: 'a', cars: [{ id: 'a', nickname: 5 }] })).toBeNull();
    expect(normCarStore({ active: 'a', cars: [{ id: 'a', evil: 1 }] })!.cars[0]).not.toHaveProperty('evil');
  });
  it('links log entries by carId; missing carId belongs to car #1', () => {
    expect(carOf({})).toBe(DEFAULT_CAR_ID);
    expect(forCar([{ carId: 'b' }, {}, { carId: DEFAULT_CAR_ID }], DEFAULT_CAR_ID)).toHaveLength(2);
    expect(normTrack({ id: 't', date: 'd', track: 'x', laps: '', carId: 'b' })!.carId).toBe('b');
    expect(normTrack({ id: 't', date: 'd', track: 'x', laps: '' })).not.toHaveProperty('carId');
    expect(normTrack({ id: 't', date: 'd', track: 'x', laps: '', carId: 7 })).toBeNull();
    expect(normSlip({ ...slip('s', 'd', 11), carId: '<x>' })).toBeNull();
    expect(normFill(fill('f', 'd', 1, 'b'))!.carId).toBe('b');
  });
  it('merges one car’s log back without touching other cars, and purges a deleted car', () => {
    const all = [{ id: '1' }, { id: '2', carId: 'b' }, { id: '3', carId: 'b' }];
    const next = mergeCarList(all, 'b', [{ id: '2', carId: 'b' }, { id: '4' }]);
    expect(next.map((e) => e.id)).toEqual(['1', '2', '4']);
    expect(next.find((e) => e.id === '4')!.carId).toBe('b');
    saveGarage({ ...EMPTY_GARAGE });
    const b = addCar({ nickname: 'B' })!;
    store.set('gt500.fuel.v1', JSON.stringify([fill('x', '2025-01-01', 1), fill('y', '2025-01-01', 2, b), { junk: true }]));
    store.set(KEYS.track, JSON.stringify([{ id: 't', date: 'd', track: 'x', laps: '', carId: b }]));
    expect(deleteCar(b)).toBe(true);
    expect(JSON.parse(store.get('gt500.fuel.v1')!)).toEqual([fill('x', '2025-01-01', 1), { junk: true }]);
    expect(JSON.parse(store.get(KEYS.track)!)).toEqual([]);
    expect(deleteCar(DEFAULT_CAR_ID)).toBe(false); // last car
    expect(purgeCarLogs('none')).toBe(true);
  });
});

describe('backup schema 6', () => {
  const v4 = { app: 'gt500-companion', schema: 4, exported: '', garage: { nickname: 'Snake', mods: [{ id: 'm', date: '2025-01-01', title: 'Tune' }] }, plans: [], track: [{ id: 't', date: '2025-01-01', track: 'VIR', laps: '' }], drag: [], fuel: [], settings: {}, onboarding: { done: true, completed: '' }, dyno: [], notify: { enabled: false, sent: {} }, dashboard: { order: [], hidden: [] } };
  it('migrates v4 → v6: single garage becomes car #1, losslessly', () => {
    expect(SCHEMA_VERSION).toBe(11);
    const m = migrate(v4);
    expect(m).toMatchObject({ schema: 11, cars: { active: DEFAULT_CAR_ID }, achievements: { seen: [] } });
    expect('garage' in m).toBe(false);
    const r = validateBackup(v4);
    expect(r.ok && r.migratedFrom).toBe(4);
    if (r.ok) {
      expect(r.data.cars.cars).toHaveLength(1);
      expect(r.data.cars.cars[0]).toMatchObject({ id: DEFAULT_CAR_ID, nickname: 'Snake' });
      expect(r.data.cars.cars[0].mods[0].title).toBe('Tune');
      expect(carOf(r.data.track[0])).toBe(DEFAULT_CAR_ID);
    }
  });
  it('migrates v5 → v6 with no achievements seen and keeps every car', () => {
    const v5 = { ...v4, schema: 5, garage: undefined, cars: { active: 'b', cars: [{ id: DEFAULT_CAR_ID, nickname: 'A' }, { id: 'b', nickname: 'B' }] }, drag: [slip('s', '2025-01-01', 11, { carId: 'b' })] };
    const r = validateBackup(v5);
    expect(r.ok && r.migratedFrom).toBe(5);
    if (r.ok) { expect(r.data.cars.active).toBe('b'); expect(r.data.achievements).toEqual({ seen: [] }); expect(r.data.drag[0].carId).toBe('b'); }
  });
  it('round-trips v6 and re-homes entries pointing at a missing car', () => {
    const b = makeBackup({ active: 'x', cars: [{ ...EMPTY_GARAGE, id: 'x', nickname: 'X' }] }, [], [], [slip('s', '2025-01-01', 11, { carId: 'gone' }), slip('t', '2025-01-01', 12)], [], undefined, undefined, undefined, { achievements: { seen: ['firstDrag'] } });
    const r = parseBackup(JSON.stringify(b));
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.migratedFrom).toBeNull();
      expect(r.data.drag.map((d) => d.carId)).toEqual(['x', 'x']);
      expect(r.data.achievements.seen).toEqual(['firstDrag']);
    }
  });
  it('restoring writes the cars key and drops the stale legacy key', () => {
    store.set(KEYS.garage, JSON.stringify({ nickname: 'Old' }));
    const r = validateBackup(v4);
    expect(r.ok && restoreBackup(r.data)).toBe(true);
    expect(store.has(KEYS.garage)).toBe(false);
    expect(loadGarage().nickname).toBe('Snake');
  });
  it('rejects malformed cars and achievements, and files newer than v7', () => {
    const base = makeBackup(EMPTY_GARAGE, [], []);
    expect(validateBackup({ ...base, cars: { active: 'a', cars: [] } }).ok).toBe(false);
    expect(validateBackup({ ...base, cars: 'x' }).ok).toBe(false);
    expect(validateBackup({ ...base, achievements: { seen: [1] } }).ok).toBe(false);
    expect(validateBackup({ ...base, schema: 12 }).ok).toBe(false);
    const bad = validateBackup({ ...v4, garage: { nickname: 5 } });
    expect(!bad.ok && bad.errors.join()).toMatch(/garage/);
  });
});

describe('iCalendar export (RFC 5545)', () => {
  it('escapes TEXT values', () => {
    expect(escapeText('a\\b;c,d\ne\r\nf')).toBe('a\\\\b\\;c\\,d\\ne\\nf');
  });
  it('folds at 75 octets without splitting UTF-8 characters', () => {
    const enc = new TextEncoder();
    const long = `SUMMARY:${'é'.repeat(60)}${'😀'.repeat(10)}${'x'.repeat(40)}`;
    const folded = foldLine(long);
    const parts = folded.split(CRLF);
    expect(parts.length).toBeGreaterThan(1);
    parts.forEach((p, i) => { expect(enc.encode(p).length).toBeLessThanOrEqual(75); if (i) expect(p.startsWith(' ')).toBe(true); });
    expect(parts.map((p, i) => (i ? p.slice(1) : p)).join('')).toBe(long); // unfolding restores the line
    expect(foldLine('SHORT:x')).toBe('SHORT:x');
  });
  it('builds a valid calendar: CRLF endings, all-day events, overdue on today, mileage-only skipped', () => {
    const r = remindersToIcs([{ id: 'car1', label: 'Snake', odometer: 9000, reminders: [
      { id: 'oil', item: 'Oil, filter; and "more"', everyMiles: 10000, everyMonths: 12, lastMiles: 1000, lastDate: '2025-06-15' },
      { id: 'brake', item: 'Brake fluid', everyMiles: null, everyMonths: 36, lastMiles: null, lastDate: '2020-01-01' },
      { id: 'plugs', item: 'Spark plugs', everyMiles: 100000, everyMonths: null, lastMiles: 0, lastDate: '' },
    ] }], '2026-01-10', new Date(Date.UTC(2026, 0, 10, 12, 0, 0)));
    expect(r.events).toBe(2);
    expect(r.skipped).toEqual(['Spark plugs']);
    expect(r.ics.endsWith(CRLF)).toBe(true);
    expect(r.ics.split(CRLF).filter(Boolean).every((l) => !/[\r\n]/.test(l))).toBe(true);
    expect(r.ics).toMatch(/^BEGIN:VCALENDAR\r\nVERSION:2\.0\r\nPRODID:/);
    expect(r.ics).toContain('DTSTART;VALUE=DATE:20260615');
    expect(r.ics).toContain('DTEND;VALUE=DATE:20260616');
    expect(r.ics).toContain('SUMMARY:Oil\\, filter\\; and "more"');
    expect(r.ics).toContain('SUMMARY:Overdue: Brake fluid');
    expect(r.ics).toContain('DTSTART;VALUE=DATE:20260110'); // overdue → today
    expect(r.ics).toContain('DTSTAMP:20260110T120000Z');
    expect(r.ics).toContain('UID:car1-oil-20260615@gt500-companion');
    expect((r.ics.match(/BEGIN:VEVENT/g) ?? []).length).toBe((r.ics.match(/END:VEVENT/g) ?? []).length);
    expect(icsDate('2026-12-31')).toBe('20261231');
  });
  it('prefixes car names when several cars are exported and handles month-end due dates', () => {
    const r = remindersToIcs([
      { id: 'a', label: 'A', odometer: null, reminders: [{ id: 'x', item: 'X', everyMiles: null, everyMonths: 1, lastMiles: null, lastDate: '2026-01-31' }] },
      { id: 'b', label: 'B', odometer: null, reminders: [{ id: 'x', item: 'X', everyMiles: null, everyMonths: 12, lastMiles: null, lastDate: '2026-02-01' }] },
    ], '2026-01-01');
    expect(r.ics).toContain('SUMMARY:A: X');
    expect(r.ics).toContain('DTSTART;VALUE=DATE:20260228');
    expect(r.ics).toContain('UID:b-x-20270201@gt500-companion');
  });
});

describe('service history report', () => {
  const car = { ...EMPTY_GARAGE, id: 'car1', nickname: '<script>alert(1)</script>', year: '2021', color: 'race-red', vin: '1FA6P8SJ0M5500000', odometer: '5000',
    service: [{ id: 's1', date: '2025-05-01', title: 'Oil & filter', notes: 'Motorcraft "FL-2087"', miles: '4000', cost: '150' }, { id: 's2', date: '2025-08-01', title: 'Brakes', notes: '', miles: '3500', cost: '$1,200' }],
    mods: [{ id: 'm1', date: '2025-02-01', title: 'Tune', notes: '', miles: '', cost: '' }] };
  it('selects only campaigns that can apply to the car year', () => {
    expect(coversYear('2021-2022', '2021')).toBe(true);
    expect(coversYear('2020', '2021')).toBe(false);
    expect(coversYear(undefined, '2021')).toBe(true);
    const list = recallChecklist('2021');
    expect(list.every((r) => r.appliesToGT500 !== 'no' && ['recall', 'nhtsa-recall', 'service-action'].includes(r.kind))).toBe(true);
    expect(list.some((r) => r.campaign === '22V083000')).toBe(true);
    expect(list.some((r) => r.campaign === '20V573000')).toBe(false);
    expect(recallChecklist('').length).toBe(recalls.filter((r) => ['recall', 'nhtsa-recall', 'service-action'].includes(r.kind) && r.appliesToGT500 !== 'no').length);
  });
  it('builds odometer history from every source and flags readings that go backwards', () => {
    const m = buildReport(car, [fill('f', '2025-06-01', 4200), fill('g', '2025-06-02', 99999, 'other')], '2026-01-01');
    expect(m.odometerHistory.map((r) => r.from)).toEqual(['service', 'fuel', 'service']);
    expect(m.odometerWarnings).toHaveLength(1);
    expect(m.serviceSpend).toBe(1350);
    expect(m.service[0].title).toBe('Oil & filter');
    expect(maskVin(car.vin, 'last6')).toMatch(/500000$/);
    expect(maskVin(car.vin, 'none')).toBe('');
  });
  it('produces a standalone HTML document with escaping, disclaimer, date and NHTSA link', () => {
    const t = (k: MsgKey, v?: Record<string, string | number>) => translate('en', k, v);
    const html = reportHtml(buildReport(car, [], '2026-01-01', 'none'), t, 'imperial', 'en');
    expect(html.startsWith('<!doctype html>')).toBe(true);
    expect(html).not.toContain('<script>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('Motorcraft &quot;FL-2087&quot;');
    expect(html).toContain('Generated on 2026-01-01');
    expect(html).toContain('Owner-entered, not verified');
    expect(html).toContain('https://www.nhtsa.gov/recalls');
    expect(html).not.toContain('1FA6P8SJ0M5500000');
    expect(html).not.toMatch(/<link|src=|<script/);
    expect(escapeHtml(`<a href="x">'&`)).toBe('&lt;a href=&quot;x&quot;&gt;&#39;&amp;');
    const esHtml = reportHtml(buildReport(car, [], '2026-01-01'), (k: MsgKey, v?: Record<string, string | number>) => translate('es', k, v), 'metric', 'es');
    expect(esHtml).toContain('lang="es"');
    expect(esHtml).toContain('no verificados');
    expect(esHtml).toContain('6,437 km'); // 4,000 mi
  });
});

describe('market value', () => {
  const fx: AuctionResult[] = [
    { id: 'a', date: '2026-01-15', venue: 'X', year: 2020, mileage: 1000, price: 100000, outcome: 'sold', cftp: true, heritage: null, description: '', source: 'https://a', confidence: 'reported' },
    { id: 'b', date: '2025-06', venue: null, year: 2021, mileage: null, price: 90000, outcome: 'sold', cftp: null, heritage: null, description: '', source: 'https://a', confidence: 'reported' },
    { id: 'c', date: null, venue: 'Y', year: 2020, mileage: 50, price: 85000, outcome: 'offer', cftp: null, heritage: null, description: '', source: 'https://a', confidence: 'unverified' },
    { id: 'd', date: '2025-09', venue: 'Z', year: 2020, mileage: 600, price: 190000, outcome: 'sold', cftp: null, heritage: null, outlier: 'celebrity', description: '', source: 'https://a', confidence: 'reported' },
    { id: 'e', date: '2025-01', venue: 'Z', year: 2022, mileage: 2000, price: null, outcome: 'sold', cftp: false, heritage: true, description: '', source: 'https://a', confidence: 'reported' },
  ];
  it('filters by year/CFTP/Heritage; unknown attributes never match yes/no; outliers and offers off by default', () => {
    expect(filterAuctions(fx, DEFAULT_FILTER).map((r) => r.id)).toEqual(['a', 'b', 'e']);
    expect(filterAuctions(fx, { ...DEFAULT_FILTER, cftp: true }).map((r) => r.id)).toEqual(['a']);
    expect(filterAuctions(fx, { ...DEFAULT_FILTER, cftp: false }).map((r) => r.id)).toEqual(['e']);
    expect(filterAuctions(fx, { ...DEFAULT_FILTER, heritage: true }).map((r) => r.id)).toEqual(['e']);
    expect(filterAuctions(fx, { ...DEFAULT_FILTER, year: 2020, includeOutliers: true, includeOffers: true }).map((r) => r.id)).toEqual(['a', 'c', 'd']);
  });
  it('charts only priced, completed sales and computes medians', () => {
    const all = { ...DEFAULT_FILTER, includeOutliers: true, includeOffers: true };
    expect(priced(filterAuctions(fx, all)).map((r) => r.id)).toEqual(['a', 'b', 'd']);
    expect(byMileage(filterAuctions(fx, all)).map((p) => p.id)).toEqual(['a', 'd']);
    expect(byDate(filterAuctions(fx, all)).map((p) => p.id)).toEqual(['a', 'b', 'd']);
    expect(median([3, 1, 2])).toBe(2); expect(median([1, 2, 3, 4])).toBe(2.5); expect(median([])).toBeNull();
    expect(dateValue('2026-01-01')).toBe(2026); expect(dateValue('2025-07')).toBeGreaterThan(2025.5);
    expect(dateValue('2025-13-01')).toBeNull(); expect(dateValue(null)).toBeNull(); expect(dateValue('Sep 2025')).toBeNull();
  });
  it('round-7 data: 15 DriveIndex sales plus named results, sourced and typed', () => {
    const di = auctionResults.filter((r) => r.source === 'https://driveindex.com/cars/ford/mustang-shelby-gt500/2020');
    expect(di).toHaveLength(15);
    expect(di.filter((r) => r.venue !== null).map((r) => r.date)).toEqual(['2026-08-17', '2026-07-14', '2026-06-11']);
    expect(di.every((r) => (r.venue === null || r.venue === 'Bring a Trailer') && r.cftp === null && r.confidence === 'reported' && r.year === 2020 && r.price! > 0)).toBe(true);
    expect(new Set(auctionResults.map((r) => r.id)).size).toBe(auctionResults.length);
    const edsel = auctionResults.find((r) => r.id === 'bat-2025-09-edsel')!;
    expect(edsel).toMatchObject({ price: 189901, mileage: 666, confidence: 'reported' });
    expect(edsel.outlier).toBeTruthy();
    expect(filterAuctions(auctionResults, DEFAULT_FILTER).some((r) => r.id === edsel.id)).toBe(false);
    const bat21 = auctionResults.find((r) => r.id === 'bat-2026-07-25')!;
    expect(bat21).toMatchObject({ price: null, cftp: true, mileage: 2500, localPrice: { amount: 91166, currency: 'GBP' } });
    const mecum = auctionResults.find((r) => r.id === 'mecum-2025-12-05')!;
    expect(mecum.confidence).toBe('unverified'); expect(mecum.price).toBeNull(); expect(mecum.conflicts).toHaveLength(2);
    expect(auctionResults.find((r) => r.id === 'bj-scottsdale-2025-1162')).toMatchObject({ mileage: 2553, price: null });
    const pcar = auctionResults.find((r) => r.id === 'pcar-offer-100mi')!;
    expect(pcar).toMatchObject({ outcome: 'offer', price: 85000, mileage: 100 });
    expect(priced(auctionResults).some((r) => r.id === pcar.id)).toBe(false);
    for (const r of auctionResults) expect(r.source).toMatch(/^https:\/\//);
    expect(median(priced(filterAuctions(auctionResults, DEFAULT_FILTER)).map((r) => r.price))).toBe(94000);
  });
  it('round-7 medians and the DriveIndex vs ConceptCarz conflict', () => {
    const v = (id: string) => marketStats.find((s) => s.id === id)!;
    expect([v('di-median-2024').value, v('di-median-2025').value, v('di-median-2026').value]).toEqual([86500, 88000, 95000]);
    expect(v('di-current').value).toBe(106367);
    expect(v('di-current').conflicts![0].value).toBe(116875);
    expect(colors.find((c) => c.id === 'wimbledon-white')).toMatchObject({ code: 'N4', confidence: 'unverified' });
    expect(colors.find((c) => c.id === 'wimbledon-white')!.note).toMatch(/2015, 2025 and 2026/);
  });
});

describe('achievements', () => {
  const cars: CarStore = { active: 'car1', cars: [
    { ...EMPTY_GARAGE, id: 'car1', odometer: '1500', service: [{ id: 's', date: '2025-01-01', title: 'Oil', notes: '', miles: '200', cost: '' }], reminders: [{ id: 'r', item: 'x', everyMiles: null, everyMonths: 1, lastMiles: null, lastDate: '2025-02-01' }] },
    { ...EMPTY_GARAGE, id: 'b' },
  ] };
  const drag = [...Array.from({ length: 9 }, (_, i) => slip(`d${i}`, `2025-03-${String(i + 1).padStart(2, '0')}`, 11.5)), slip('fast', '2025-04-01', 10.9), slip('gps', '2025-04-02', null, { gps: { kind: '0-60', seconds: 3.5, trapMph: null, accuracyM: 3 } })];
  const list = computeAchievements({ cars, track: [{ id: 't', date: '2025-05-05', track: 'VIR', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: '2:50.1\n2:49.0', notes: '' }], drag, fuel: [fill('f1', '2025-06-01', 900), fill('f2', '2025-07-01', 1300)], dyno: [], plans: 0 });
  const a = (id: string) => list.find((x) => x.id === id)!;
  it('derives milestones and their dates from logged data', () => {
    expect(a('firstTrack')).toMatchObject({ done: true, date: '2025-05-05' });
    expect(a('drag10')).toMatchObject({ done: true, current: 10, date: '2025-04-01' }); // GPS run excluded
    expect(a('tenSecond')).toMatchObject({ done: true, date: '2025-04-01' });
    expect(a('miles1k')).toMatchObject({ done: true, date: '2025-07-01' }); // 200 → 1300 crosses 1,000 on the fill-up
    expect(a('miles10k').done).toBe(false);
    expect(a('twoCars').done).toBe(true);
    expect(a('maintained').date).toBe('2025-02-01');
    expect(a('firstDyno')).toMatchObject({ done: false, current: 0, date: null });
    expect(a('laps100').current).toBe(2);
    expect(milesLogged({ cars, track: [], drag: [], fuel: [], dyno: [], plans: 0 }).miles).toBe(1300); // 200 → current 1500
    for (const x of list) { expect(en[x.title]).toBeTruthy(); expect(es[x.desc]).toBeTruthy(); }
  });
  it('tracks which unlocks were already seen', () => {
    expect(unseen(list, { seen: ['firstTrack'] })).not.toContain('firstTrack');
    expect(normAch({ seen: ['a', 'a'] })).toEqual({ seen: ['a'] });
    expect(normAch({ seen: 'x' })).toBeNull();
    expect(normAch([])).toBeNull();
  });
});

describe('keyboard shortcuts', () => {
  it('maps /, ?, g-sequences and Escape; ignores typing and modifier chords', () => {
    let now = 0;
    const m = createShortcuts(() => now);
    expect(m({ key: '/' })).toEqual({ kind: 'search' });
    expect(m({ key: '?' })).toEqual({ kind: 'help' });
    expect(m({ key: 'g' })).toBeNull();
    expect(m({ key: 'h' })).toEqual({ kind: 'go', to: '/' });
    m({ key: 'g' }); expect(m({ key: 's' })).toEqual({ kind: 'go', to: '/specs' });
    m({ key: 'g' }); now = 5000; expect(m({ key: 'h' })).toBeNull(); // timed out
    expect(m({ key: 'h' })).toBeNull();
    expect(m({ key: '/', target: { tagName: 'INPUT', type: 'text' } })).toBeNull();
    expect(m({ key: '/', target: { tagName: 'TEXTAREA' } })).toBeNull();
    expect(m({ key: '?', target: { tagName: 'DIV', isContentEditable: true } })).toBeNull();
    expect(m({ key: '/', ctrlKey: true })).toBeNull();
    m({ key: 'g' }); expect(m({ key: 'h', target: { tagName: 'SELECT' } })).toBeNull();
    expect(m({ key: 'Escape' })).toEqual({ kind: 'close' });
    expect(isTyping({ tagName: 'INPUT', type: 'checkbox' })).toBe(false);
    expect(isTyping(null)).toBe(false);
    for (const v of Object.values(GO)) expect(en[v.key as keyof typeof en]).toBeTruthy();
  });
});

describe('notifications across cars', () => {
  it('keeps car #1 keys unprefixed (history carries over) and prefixes other cars', () => {
    const r = [{ id: 'oil', item: 'Oil', everyMiles: null, everyMonths: 1, lastMiles: null, lastDate: '2020-01-01' }];
    expect(dueAlerts(r, null, '2026-01-01', {}, { id: DEFAULT_CAR_ID, label: '' })[0]).toMatchObject({ id: 'oil', title: 'Overdue: Oil' });
    expect(dueAlerts(r, null, '2026-01-01', {}, { id: 'b', label: 'Blue' })[0]).toMatchObject({ id: 'b:oil', title: 'Overdue: Blue — Oil' });
  });
});

describe('i18n completeness', () => {
  it('plural forms pick singular for n = 1', () => {
    expect(translate('en', 'timer.saved', { n: 1 })).toBe('Saved 1 lap to the Track log.');
    expect(translate('en', 'timer.saved', { n: 2 })).toBe('Saved 2 laps to the Track log.');
    expect(translate('es', 'timer.saved', { n: 1 })).toBe('Se guardó 1 vuelta en el registro de pista.');
    expect(translate('es', 'home.counts', { mods: 1, svc: 2, plans: 0, track: 1 })).toBe('1 modificación · 2 servicios · 0 planes · 1 sesión de pista');
  });
  it('every key exists, non-empty, in both languages with the same placeholders', () => {
    expect(missingKeys('es')).toEqual([]);
    const keys = Object.keys(en) as (keyof typeof en)[];
    expect(Object.keys(es).sort()).toEqual([...keys].sort());
    const ph = (s: string) => (s.match(/\{\w+\}/g) ?? []).sort().join();
    for (const k of keys) {
      expect(es[k].trim(), k).not.toBe('');
      expect(ph(es[k]), k).toBe(ph(en[k]));
    }
  });
});

async function render(name: string, lang: Lang = 'en', path = '/', route = '/', ctx?: Parameters<typeof CarContext.Provider>[0]['value']) {
  const { PAGES } = await import('../src/App');
  const { default: Page } = await PAGES[name as keyof typeof PAGES]();
  const car = ctx ?? { active: activeCar(loadCars()).id, cars: loadCars().cars.map((c, i) => ({ id: c.id, label: carLabel(c, i) })), version: 0, switchCar: () => undefined, refresh: () => undefined };
  return renderToString(
    <SettingsContext.Provider value={{ settings: { units: 'imperial', theme: 'dark', lang }, setSettings: () => undefined }}>
      <CarContext.Provider value={car}>
        <MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={<Page />} /></Routes></MemoryRouter>
      </CarContext.Provider>
    </SettingsContext.Provider>,
  ).replace(/<!-- -->/g, '');
}

describe('round-8 pages render', () => {
  const seedTwo = () => {
    saveGarage({ ...EMPTY_GARAGE, nickname: 'Snake', year: '2020', odometer: '3000', service: [{ id: 's', date: '2025-01-01', title: 'Oil change', notes: '', miles: '2500', cost: '150' }] });
    addCar({ nickname: 'Blue', year: '2022' });
    setActiveCar(DEFAULT_CAR_ID);
    store.set('gt500.drag.v1', JSON.stringify([slip('a', '2025-02-01', 11.1), slip('b', '2025-02-02', 10.8, { carId: 'zz', track: 'OtherCarTrack' })]));
  };
  it('Garage shows the car manager and only the active car’s data', async () => {
    seedTwo();
    const h = await render('Garage');
    for (const s of ['Your cars', 'Snake', 'Blue', 'Add another car', 'Delete this car', 'Download calendar (.ics)', 'Calendar for all cars (.ics)', 'Service history report']) expect(h).toContain(s);
    const hs = await render('Garage', 'es');
    for (const s of ['Mi garaje', 'Sus autos', 'Agregar otro auto', 'Recordatorios de mantenimiento', 'Descargar calendario (.ics)']) expect(hs).toContain(s);
  });
  it('Drag log lists only the active car’s passes', async () => {
    seedTwo();
    const h = await render('Drag');
    expect(h).not.toContain('OtherCarTrack');
  });
  it('Report renders with disclaimer, generated date, recall checklist and VIN options', async () => {
    seedTwo();
    const h = await render('Report');
    for (const s of ['Service history — Snake', 'Owner-entered, not verified', 'Generated on', 'Recall &amp; campaign checklist', 'Print / save as PDF', 'Download HTML', 'Oil change', 'Last 6 characters only', 'nhtsa.gov/recalls']) expect(h).toContain(s);
    expect(await render('Report', 'es')).toContain('no verificados');
  });
  it('Market renders round-7 data, charts and the empty state', async () => {
    saveGarage({ ...EMPTY_GARAGE, odometer: '2000', year: '2020' });
    const h = await render('Market');
    for (const s of ['Market Value', 'Price vs sale date', 'Price vs mileage', 'Your car: 2,000 mi', 'Bring a Trailer', 'GBP 91,166', 'Include outliers', 'Include offers that were not sales', 'Conflicting source', '$116,875', '$106,367', 'Show my car’s year (2020)']) expect(h).toContain(s);
    expect(h).not.toContain('Edsel'); // outlier hidden by default
    const { default: Market } = await import('../src/pages/Market');
    const empty = renderToString(<MemoryRouter><Market results={[]} stats={[]} /></MemoryRouter>);
    expect(empty).toContain('No auction results yet');
    expect(empty).not.toContain('<svg');
    expect(await render('Market', 'es')).toContain('Valor de mercado');
  });
  it('Achievements renders progress and Spanish', async () => {
    seedTwo();
    const h = await render('Achievements');
    for (const s of ['Achievements', 'First pass', '10 drag passes', '1,000 miles logged', 'Collector', 'Reached 2025-02-01']) expect(h).toContain(s);
    expect(await render('Achievements', 'es')).toContain('Logros');
  });
  it('Settings lists keyboard shortcuts; Timeline offers all cars; Share offers "Add as a new car"', async () => {
    seedTwo();
    expect(await render('Settings')).toContain('Keyboard shortcuts');
    const tl = await render('Timeline');
    expect(tl).toContain('Show all cars');
    expect(tl).toContain('Oil change');
    expect(await render('Welcome', 'es')).toContain('Bienvenida');
  });
});

describe('Spanish UI on every page', () => {
  it('every route renders in both languages and its heading is translated', async () => {
    const { PAGES } = await import('../src/App');
    const routes: Record<string, [string, string]> = { Guide: ['/guides/track-service', '/guides/:id'], Share: ['/share/x', '/share/:data'] };
    const h1 = (h: string) => /<h1[^>]*>(.*?)<\/h1>/.exec(h)?.[1] ?? '';
    const same: string[] = [];
    for (const name of Object.keys(PAGES)) {
      const [path, route] = routes[name] ?? ['/', '/'];
      const enH = await render(name, 'en', path, route);
      const esH = await render(name, 'es', path, route);
      expect(h1(esH), name).not.toBe('');
      if (h1(enH) === h1(esH)) same.push(name);
    }
    // Only headings that are proper names or data (guide titles, shared-link errors) may stay the same.
    expect(same.filter((n) => !['Guide'].includes(n))).toEqual([]);
  });
});

describe('GitHub Pages workflow', () => {
  it('deploys dist/ only on manual workflow_dispatch, never on push', async () => {
    const { readFileSync } = await import('node:fs');
    const y = readFileSync('.github/workflows/pages.yml', 'utf8');
    const on = /\non:\n((?: {2}.*\n)+)/.exec(y)![1];
    expect(on.trim()).toBe('workflow_dispatch:');
    expect(y).not.toMatch(/^\s*(push|pull_request|schedule|release):/m);
    expect(y).toMatch(/path: dist/);
    expect(y).toMatch(/actions\/deploy-pages@v4/);
    expect(readFileSync('vite.config.ts', 'utf8')).toMatch(/base: '\.\/'/);
  });
});
