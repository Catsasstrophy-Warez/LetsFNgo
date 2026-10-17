import { describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import {
  ELM_INIT, MAP_MAX_KPA, ObdClient, ReadOnlyError, assertReadOnly, boostKpa, cleanResponse, decodeDtc, demoTransport, dtcLookupUrl, encodeSupported,
  fakeTransport, parseDtcs, parseMode01, parseSupported, readPidValue, samplesCsv, summarize,
} from '../src/lib/obd';
import { classify, lightsAt, normResult, randomDelay, schedule, stats, MIN_DELAY_MS, MAX_DELAY_MS, TIMEOUT_MS } from '../src/lib/tree';
import { ask, matchColors, normQ } from '../src/lib/ask';
import { daysUntil, normTrackDay, splitDays, trackDaysToIcs, type TrackDay } from '../src/lib/trackdays';
import { SCHEMA_VERSION, makeBackup, migrate, validateBackup, ALL_KEYS } from '../src/lib/backup';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { addPhoto, allPhotos, memoryBackend, restorePhotos, setPhotoBackend, MAX_TOTAL_BYTES, type Encoder } from '../src/lib/photos';
import { newUserItemId } from '../src/components/PreTrack';
import { detectCrossings, projector, sourcedTimingLines } from '../src/lib/lapTimer';
import { startFinishLines } from '../src/data/startFinishLines';
import { competitors } from '../src/data/competitors';
import { checkCollections } from '../src/lib/dataSchema';
import { collections } from '../src/data';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { listFiles } from '../vite.config';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });

const wrap = (el: JSX.Element, lang: 'en' | 'es' = 'en', units: 'imperial' | 'metric' = 'imperial') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang, units }, setSettings: () => undefined }}><MemoryRouter>{el}</MemoryRouter></SettingsContext.Provider>,
);

describe('OBD-II parsing (SAE J1979)', () => {
  it('decodes the standard Mode 01 PIDs', () => {
    expect(readPidValue('rpm', '410C1AF8\r\r>')).toBe(1726);
    expect(readPidValue('rpm', '41 0C 1A F8')).toBe(1726);
    expect(readPidValue('speed', '410D64')).toBe(100);
    expect(readPidValue('coolant', '41057B')).toBe(83);
    expect(readPidValue('iat', '410F28')).toBe(0);
    expect(readPidValue('map', '410BFF')).toBe(MAP_MAX_KPA);
    expect(readPidValue('throttle', '4111FF')).toBe(100);
    expect(readPidValue('oil', '415C82')).toBe(90);
    expect(readPidValue('baro', '413365')).toBe(101);
  });
  it('skips echo, SEARCHING and other ECUs, and reports adapter errors as null', () => {
    expect(parseMode01('0D', 'SEARCHING...\r7E8 03 41 0D 32\r410D32\r>')).toEqual([0x32]);
    expect(readPidValue('speed', 'NO DATA\r>')).toBeNull();
    expect(readPidValue('speed', 'UNABLE TO CONNECT')).toBeNull();
    expect(readPidValue('speed', '?')).toBeNull();
    expect(readPidValue('speed', '410C1AF8')).toBeNull(); // wrong PID
    expect(readPidValue('rpm', '410C1A')).toBeNull(); // too short
    expect(cleanResponse('CAN ERROR\r>')).toEqual({ error: 'busError' });
  });
  it('reads supported-PID bitmaps (bit 7 of byte 0 is base + 1)', () => {
    expect(parseSupported(0, [0xbe, 0x1f, 0xa8, 0x13])).toEqual([1, 3, 4, 5, 6, 7, 12, 13, 14, 15, 16, 17, 19, 21, 28, 31, 32]);
    expect(parseSupported(0x40, [0x00, 0x00, 0x00, 0x10])).toEqual([0x5c]);
    expect(parseSupported(0x20, hexOf(encodeSupported(0x20, [0x33, 0x40])))).toEqual([0x33, 0x40]);
  });
  it('computes boost as MAP − baro', () => {
    expect(boostKpa({ map: 180, baro: 100 })).toBe(80);
    expect(boostKpa({ map: 40, baro: 100 })).toBe(-60);
    expect(boostKpa({ map: 180, baro: null })).toBeNull();
  });
});
const hexOf = (s: string) => s.match(/../g)!.map((x) => parseInt(x, 16));

describe('DTC decoding (Mode 03 / 07)', () => {
  it('decodes P/C/B/U and generic vs manufacturer codes', () => {
    expect(decodeDtc(0x01, 0x33)).toEqual({ code: 'P0133', system: 'P', generic: true });
    expect(decodeDtc(0x11, 0x23)?.code).toBe('P1123');
    expect(decodeDtc(0x11, 0x23)?.generic).toBe(false);
    expect(decodeDtc(0x41, 0x23)?.code).toBe('C0123');
    expect(decodeDtc(0x82, 0x34)?.code).toBe('B0234');
    expect(decodeDtc(0xc1, 0x00)?.code).toBe('U0100');
    expect(decodeDtc(0x34, 0x56)).toMatchObject({ code: 'P3456', generic: true });
    expect(decodeDtc(0x30, 0x00)).toMatchObject({ code: 'P3000', generic: false });
    expect(decodeDtc(0, 0)).toBeNull();
  });
  it('parses legacy, CAN single-frame, multi-frame and NO DATA replies', () => {
    expect(parseDtcs('03', '43 01 33 00 00 00 00\r>')!.map((d) => d.code)).toEqual(['P0133']);
    expect(parseDtcs('03', '43020133C100\r>')!.map((d) => d.code)).toEqual(['P0133', 'U0100']);
    expect(parseDtcs('07', '4701 0300\r>')!.map((d) => d.code)).toEqual(['P0300']);
    expect(parseDtcs('03', '00A\r0:43040133C100\r1:03000171\r>')!.map((d) => d.code)).toEqual(['P0133', 'U0100', 'P0300', 'P0171']);
    expect(parseDtcs('03', 'NO DATA\r>')).toEqual([]);
    expect(parseDtcs('03', 'UNABLE TO CONNECT\r>')).toBeNull();
    expect(parseDtcs('07', '43020133\r>')).toBeNull(); // a Mode 03 reply is not a Mode 07 answer
  });
  it('links codes to a generic lookup over https', () => {
    expect(dtcLookupUrl('P0133')).toBe('https://www.obd-codes.com/p0133');
  });
});

describe('read-only guard', () => {
  it('refuses Mode 04, writes and unknown AT commands; allows reads', () => {
    for (const bad of ['04', '0400', '08', '2E1234', '2F', '31', '3B', '14', 'ATMA', 'ATPP', 'AT@3', '0', '010C00', '22F40C']) expect(() => assertReadOnly(bad), bad).toThrow(ReadOnlyError);
    for (const ok of [...ELM_INIT, '010C', '01 0d', '0100', '03', '07']) expect(() => assertReadOnly(ok), ok).not.toThrow();
  });
  it('a full session over the fake transport never sends anything but init, Mode 01, 03 and 07', async () => {
    const tr = fakeTransport({ values: () => ({ rpm: 3000, speed: 80, coolant: 90, iat: 30, map: 150, baro: 100, throttle: 50 }), stored: ['P0133'], pending: ['P0300'] });
    const c = new ObdClient(tr);
    await c.init();
    const sup = await c.readSupported();
    expect([...sup]).toEqual(expect.arrayContaining([0x0c, 0x0d, 0x05, 0x0f, 0x0b, 0x11, 0x33]));
    expect(c.isSupported('oil')).toBe(false); // 5C not reported → hidden
    const r = await c.read(['rpm', 'speed', 'coolant', 'iat', 'map', 'baro', 'throttle', 'oil']);
    expect(r).toMatchObject({ rpm: 3000, speed: 80, coolant: 90, iat: 30, map: 150, baro: 100, oil: null });
    expect(r.throttle).toBeCloseTo(50, 0);
    const d = await c.readDtcs();
    expect(d.stored!.map((x) => x.code)).toEqual(['P0133']);
    expect(d.pending!.map((x) => x.code)).toEqual(['P0300']);
    expect(tr.log.every((cmd) => /^(AT\w+|01[0-9A-F]{2}|03|07)$/.test(cmd))).toBe(true);
    expect(tr.log).not.toContain('04');
    await expect(c.cmd('04')).rejects.toThrow(ReadOnlyError);
    expect(tr.log).not.toContain('04');
  });
  it('follows the bitmap chain to 40 when oil temp is reported, and stops when a range is unsupported', async () => {
    const tr = fakeTransport({ supported: [0x0c, 0x5c], values: () => ({ oil: 100, rpm: 900 }) });
    const c = new ObdClient(tr);
    await c.readSupported();
    expect(c.isSupported('oil')).toBe(true);
    expect(tr.log).toEqual(['0100', '0120', '0140']);
    expect((await c.read(['oil'])).oil).toBe(100);
  });
  it('demo transport is flagged simulated', async () => {
    const c = new ObdClient(demoTransport(() => 10_000));
    await c.init(); await c.readSupported();
    expect(c.simulated).toBe(true);
    const r = await c.read(['rpm', 'speed']);
    expect(r.rpm).toBeGreaterThan(0);
  });
  it('summarizes and exports CSV with a simulated column', () => {
    const s = [{ t: 0, r: { rpm: 1000, speed: 10, coolant: 80, iat: 20, map: 100, baro: 100, throttle: 10, oil: null } }, { t: 1500, r: { rpm: 6000, speed: 150, coolant: 95, iat: 35, map: 190, baro: 100, throttle: 99, oil: null } }];
    expect(summarize(s)).toMatchObject({ n: 2, seconds: 1.5, rpm: 6000, speed: 150, coolant: 95, boost: 90, oil: null });
    const csv = samplesCsv(s, true);
    expect(csv.split('\r\n')[0]).toBe('t_s,rpm,speed_kmh,coolant_c,iat_c,map_kpa,baro_kpa,boost_kpa,throttle_pct,oil_c,simulated');
    expect(csv.split('\r\n')[2]).toBe('1.5,6000,150,95,35,190,100,90,99,,yes');
  });
});

describe('drag tree trainer', () => {
  it('schedules sportsman (.5 full) and pro (.4) trees', () => {
    expect(schedule('sportsman', 1000)).toEqual({ mode: 'sportsman', ambers: [1000, 1500, 2000], green: 2500 });
    expect(schedule('pro', 1000)).toEqual({ mode: 'pro', ambers: [1000, 1000, 1000], green: 1400 });
    expect(randomDelay(0)).toBe(MIN_DELAY_MS);
    expect(randomDelay(0.9999)).toBeLessThanOrEqual(MAX_DELAY_MS);
  });
  it('classifies reaction times and red lights', () => {
    const s = schedule('pro', 1000);
    expect(classify(s, 1400, 'd')).toEqual({ mode: 'pro', rt: 0, red: false, date: 'd' });
    expect(classify(s, 1612, 'd')?.rt).toBe(0.212);
    expect(classify(s, 1395, 'd')).toMatchObject({ rt: -0.005, red: true });
    expect(classify(s, 500, 'd')?.red).toBe(true); // before the first amber
    expect(classify(s, 1400 + TIMEOUT_MS + 1)).toBeNull();
    expect(lightsAt(s, 1200)).toEqual({ ambers: 3, green: false, red: false });
    expect(lightsAt(s, 1400)).toEqual({ ambers: 0, green: true, red: false });
    expect(lightsAt(schedule('sportsman', 0), 600)).toMatchObject({ ambers: 2 });
    expect(lightsAt(s, 1300, true)).toMatchObject({ red: true, green: false });
  });
  it('stats count good runs only; stored results are validated', () => {
    const l = [{ mode: 'pro' as const, rt: 0.2, red: false, date: '' }, { mode: 'pro' as const, rt: 0, red: false, date: '' }, { mode: 'pro' as const, rt: -0.01, red: true, date: '' }, { mode: 'sportsman' as const, rt: 0.5, red: false, date: '' }];
    expect(stats(l, 'pro')).toEqual({ runs: 3, reds: 1, best: 0, avg: 0.1, perfect: 1 });
    expect(normResult({ mode: 'pro', rt: 'x', date: '' })).toBeNull();
    expect(normResult({ mode: 'pro', rt: -0.1, red: false, date: 'd' })?.red).toBe(true);
  });
});

describe('ask the data', () => {
  it('answers from sourced records only, with sources', () => {
    const oil = ask('What oil does it take?')!;
    expect(oil.intent).toBe('oil');
    expect(oil.facts.some((f) => /5W-50/.test(f.value))).toBe(true);
    expect(oil.facts.every((f) => f.source.startsWith('https://') && f.confidence)).toBe(true);
    expect(ask('0-60')!.facts[0].value).toMatch(/3\.3 s/);
    expect(ask('zero to sixty time')!.intent).toBe('zeroSixty');
    expect(ask('paint code for grabber lime')!.facts.map((f) => f.value)).toEqual(['F9 (M7435)']);
    expect(ask('código de pintura Rapid Red')!.facts[0].value).toBe('D4');
    expect(ask('recalls')!.facts.length).toBeGreaterThan(0);
    expect(ask('¿Qué aceite usa?')!.intent).toBe('oil');
    expect(ask('2021 MSRP')!.facts.every((f) => f.label.startsWith('2021'))).toBe(true);
    expect(ask('horsepower')!.facts[0].value).toMatch(/760/);
  });
  it('says "not in the data" otherwise', () => {
    expect(ask('who won the 1967 Le Mans')).toBeNull();
    expect(ask('paint code for purple polka dots')).toBeNull();
    expect(ask('')).toBeNull();
  });
  it('normalizes accents and dashes', () => {
    expect(normQ('0–60 ¿Pintura?')).toBe('0-60 pintura');
    expect(matchColors('grabber yellow')[0].c.id).toBe('grabber-yellow');
  });
});

describe('track day planner', () => {
  const ev = (o: Partial<TrackDay> = {}): TrackDay => ({ id: 'e1', date: '2026-11-07', endDate: '', trackId: 'road-america', track: 'Road America', group: 'Novice', org: 'Club; Inc, LLC', notes: '', pack: [{ id: 'p1', label: 'Helmet', done: false }], ...o });
  it('validates events', () => {
    expect(normTrackDay(ev())).toEqual(ev());
    expect(normTrackDay(ev({ date: '2026-02-30' }))).toBeNull();
    expect(normTrackDay(ev({ track: ' ' }))).toBeNull();
    expect(normTrackDay(ev({ endDate: '2026-11-01' }))?.endDate).toBe('');
  });
  it('splits upcoming/past (a multi-day event in progress is upcoming) and counts days', () => {
    const l = [ev({ id: 'a', date: '2026-10-01' }), ev({ id: 'b', date: '2026-10-16', endDate: '2026-10-18' }), ev({ id: 'c', date: '2026-12-01' })];
    const s = splitDays(l, '2026-10-17');
    expect(s.upcoming.map((d) => d.id)).toEqual(['b', 'c']);
    expect(s.past.map((d) => d.id)).toEqual(['a']);
    expect(daysUntil('2026-10-20', '2026-10-17')).toBe(3);
  });
  it('exports RFC 5545 all-day events with escaping and exclusive DTEND', () => {
    const ics = trackDaysToIcs([ev(), ev({ id: 'e2', date: '2026-12-30', endDate: '2026-12-31' })], new Date('2026-10-17T00:00:00Z'));
    expect(ics.startsWith('BEGIN:VCALENDAR\r\n')).toBe(true);
    expect(ics).toContain('DTSTART;VALUE=DATE:20261107\r\nDTEND;VALUE=DATE:20261108');
    expect(ics).toContain('DTEND;VALUE=DATE:20270101');
    expect(ics).toContain('Organizer: Club\\; Inc\\, LLC');
    expect(ics.split('\r\n').every((l) => new TextEncoder().encode(l).length <= 75)).toBe(true);
  });
});

describe('backup v9', () => {
  it('adds trackdays and migrates v8 files', () => {
    expect(SCHEMA_VERSION).toBe(11);
    expect(migrate({ schema: 8 })).toMatchObject({ schema: 11, trackdays: [] });
    const b = makeBackup(EMPTY_GARAGE, [], [], [], [], undefined, undefined, undefined, { trackdays: [{ id: 'e1', date: '2026-11-07', endDate: '', trackId: '', track: 'X', group: '', org: '', notes: '', pack: [] }] });
    const r = validateBackup(JSON.parse(JSON.stringify(b)));
    expect(r.ok && r.data.trackdays.length).toBe(1);
    expect(validateBackup({ ...b, trackdays: [{ id: 'x' }] }).ok).toBe(false);
    const v8 = { ...b, schema: 8 } as Record<string, unknown>; delete v8.trackdays;
    const m = validateBackup(v8);
    expect(m.ok && m.migratedFrom).toBe(8);
  });
  it('reset covers the new keys', () => {
    expect(ALL_KEYS).toEqual(expect.arrayContaining(['gt500.trackdays.v1', 'gt500.tree.v1']));
  });
});

describe('bug fixes (round 13)', () => {
  const enc: Encoder = async (b) => ({ blob: b, thumb: new Blob(['t']), w: 10, h: 10 });
  it('restorePhotos keeps the existing photos when a backup photo cannot be decoded', async () => {
    setPhotoBackend(memoryBackend());
    await addPhoto({ kind: 'service', id: 's1' }, new Blob(['x'], { type: 'image/jpeg' }), enc);
    await expect(restorePhotos([{ id: 'pabcd1', kind: 'mod', ownerId: 'm1', created: '2026-01-01', w: 1, h: 1, data: '%%%not base64' }], enc)).rejects.toThrow();
    expect((await allPhotos()).map((p) => p.ownerId)).toEqual(['s1']);
    setPhotoBackend(null);
  });
  it('restorePhotos never exceeds the device size quota once thumbnails are added', async () => {
    setPhotoBackend(memoryBackend());
    const big = btoa('x'.repeat(1_200_000));
    const list = Array.from({ length: 40 }, (_, i) => ({ id: `pphoto${i}`, kind: 'mod' as const, ownerId: `m${i}`, created: '2026-01-01', w: 1, h: 1, data: big }));
    const fatThumb: Encoder = async (b) => ({ blob: b, thumb: new Blob(['t'.repeat(90_000)]), w: 1, h: 1 });
    const n = await restorePhotos(list, fatThumb);
    const all = await allPhotos();
    expect(all.length).toBe(n);
    expect(all.reduce((a, p) => a + p.bytes, 0)).toBeLessThanOrEqual(MAX_TOTAL_BYTES);
    setPhotoBackend(null);
  });
  it('owner checklist items added in the same millisecond get distinct ids', () => {
    const a = newUserItemId([], 1000);
    const b = newUserItemId([{ id: a }], 1000);
    const c = newUserItemId([{ id: a }, { id: b }], 1000);
    expect(new Set([a, b, c]).size).toBe(3);
  });
  it('every OSM line with a direction counts travel along its way bearing (+1) and refuses the reverse', () => {
    for (const l of startFinishLines.filter((x) => x.direction)) {
      const bearing = Number(/Bearing about ([\d.]+) deg/.exec(l.note ?? '')?.[1]);
      expect(Number.isFinite(bearing), l.id).toBe(true);
      const mid = { lat: (l.a.lat + l.b.lat) / 2, lon: (l.a.lon + l.b.lon) / 2 };
      const P = projector(mid);
      const b = (bearing * Math.PI) / 180;
      const pass = (sign: number) => [-60, -20, 20, 60].map((m, i) => ({ ...P.toLatLon({ x: sign * m * Math.sin(b), y: sign * m * Math.cos(b) }), t: i * 1000, accuracy: 3, speed: 20 }));
      const { line } = sourcedTimingLines(l);
      expect(detectCrossings(pass(1), line, { minMs: 0, smooth: false }).length, l.id).toBe(1);
      expect(detectCrossings(pass(-1), line, { minMs: 0, smooth: false }).length, l.id).toBe(0);
    }
  });
});

describe('competitor prices (round 11 research)', () => {
  it('carries year, destination flag, source and confidence; 1LE stays 2018-only', () => {
    const p = (id: string) => competitors.find((c) => c.id === id)!.prices!;
    expect(p('zl1-auto').map((x) => [x.modelYear, x.value, x.destinationIncluded])).toEqual([[2020, 63000, false], [2020, 69000, false], [2022, 64395, true], [2022, 69000, true]]);
    expect(p('hellcat')[0]).toMatchObject({ modelYear: 2020, value: 58995 });
    expect(p('redeye').map((x) => x.value)).toEqual([70595, 76595, 81060, 76430, 78225]);
    expect(p('hellcat').filter((x) => x.modelYear > 2020).every((x) => x.confidence === 'unverified')).toBe(true);
    expect(p('redeye')[1].confidence).toBe('unverified');
    expect(p('jailbreak')).toEqual([expect.objectContaining({ modelYear: 2022, value: 995 })]);
    expect(p('zl1').every((x) => x.modelYear === 2018)).toBe(true);
    expect(checkCollections(collections)).toEqual([]);
  });
});

describe('new pages render (en + es) and i18n parity', () => {
  it('every new key exists in Spanish', () => {
    for (const k of Object.keys(en).filter((k) => /^(obd|tree|ask|td|pack)\./.test(k) || ['nav.obd', 'nav.tree', 'nav.ask', 'nav.trackdays'].includes(k))) expect(es[k as keyof typeof es], k).toBeTruthy();
  });
  it.each(['Obd', 'Tree', 'Ask', 'TrackDays'])('%s renders in both languages', async (name) => {
    const { default: Page } = await import(`../src/pages/${name}.tsx`);
    const h = wrap(<Page />);
    expect(h).toContain('<h1>');
    expect(wrap(<Page />, 'es', 'metric')).toContain('<h1>');
  });
  it('OBD page shows the safety note and explains unsupported browsers', async () => {
    const { default: Obd } = await import('../src/pages/Obd');
    const h = wrap(<Obd />);
    expect(h).toContain('do not look at or touch this screen while driving');
    expect(h).toContain('iPhone and iPad browsers');
    expect(h).toContain('Mode 22');
    expect(h).toContain('forum.hptuners.com');
  });
});

describe('preview manifest', () => {
  it('lists files recursively with POSIX paths', () => {
    const d = mkdtempSync(join(tmpdir(), 'pm-'));
    mkdirSync(join(d, 'assets'));
    writeFileSync(join(d, 'index.html'), 'x'); writeFileSync(join(d, 'assets', 'a.js'), 'y');
    expect(listFiles(d)).toEqual(['assets/a.js', 'index.html']);
  });
});
