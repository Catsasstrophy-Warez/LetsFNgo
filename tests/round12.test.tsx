import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS, normalizeSettings } from '../src/lib/units';
import { fmtLap, isOsmSource, linesForTrack, radialLine, sessionFromFixes, sourcedTimingLines, syntheticCircuit } from '../src/lib/lapTimer';
import { SPEED_COLORS, fitMap, lapPoints, nearestIndex, sectorTable, speedBins } from '../src/lib/trackMap';
import {
  MAX_PER_OWNER, MAX_TOTAL_BYTES, PhotoError, addPhoto, allPhotos, b64ToBytes, bytesToB64, checkQuota, deletePhotosFor, fitWithin, memoryBackend,
  photosFor, photosToBackup, restorePhotos, setPhotoBackend, type Encoder,
} from '../src/lib/photos';
import { normChecklist, normGpsSession, normPhotoBackup, normTrack } from '../src/lib/validate';
import { MAX_IMPORT_BYTES, SCHEMA_VERSION, buildExport, makeBackup, migrate, parseBackup, validateBackup } from '../src/lib/backup';
import { SOURCED_CHECKS, factFor, freshChecklist, tirePressuresSourced } from '../src/lib/preTrack';
import { loadPtc, normPtc, PTC_KEY } from '../src/lib/ptc';
import { AA, THEME_BGS, contrast, deriveAccent, hexToRgb } from '../src/lib/accent';
import { colors } from '../src/data/colors';
import { collections } from '../src/data';
import { tracks } from '../src/data/tracks';
import { startFinishLines } from '../src/data/startFinishLines';
import { MAY_BE_EMPTY, SCHEMAS, checkCollections } from '../src/lib/dataSchema';
import { computeCoverage, routeFor } from '../src/lib/coverage';
import { rankedSearch } from '../src/lib/search';
import { translate, en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { TrackMap } from '../src/components/TrackMap';
import { SourcedLinePicker } from '../src/components/SourcedLine';
import { PreTrackChecklist, SavedChecklist } from '../src/components/PreTrack';
import type { StartFinishLine } from '../src/data/types';
import type { Sourced } from '../src/data/types';
import { readFileSync } from 'node:fs';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });

const wrap = (el: JSX.Element, units: 'imperial' | 'metric' = 'imperial', lang: 'en' | 'es' = 'en') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, units, lang }, setSettings: () => undefined }}>
    <MemoryRouter>{el}</MemoryRouter>
  </SettingsContext.Provider>,
);

/** A stored GPS session of the synthetic circuit with two sector lines. */
function storedSession() {
  const fixes = syntheticCircuit({ laps: 3.3 });
  const s = sessionFromFixes(fixes, radialLine(-Math.PI / 2), [radialLine(0), radialLine(Math.PI)]);
  if (!s) throw new Error('no session');
  return s.gps;
}

describe('bug fixes (round 12)', () => {
  it('fmtLap rounds before splitting minutes (59.9996 s is 1:00.000, not 0:60.000)', () => {
    expect(fmtLap(59.9996)).toBe('1:00.000');
    expect(fmtLap(119.9999)).toBe('2:00.000');
    expect(fmtLap(47.1239)).toBe('0:47.124');
  });
  it('search results for every collection link to the page that shows them (not Home)', () => {
    expect(rankedSearch('Signature Edition').find((h) => h.collection === 'editions')?.route).toBe('/editions');
    expect(rankedSearch('Laguna Seca').find((h) => h.collection === 'tracks')?.route).toBe('/laptimer');
    for (const name of Object.keys(collections)) expect(routeFor(name, {}), name).not.toBe('/');
    const g = rankedSearch('track-day maintenance').find((h) => h.collection === 'guides');
    expect(g?.route).toMatch(/^\/guides\//);
  });
  it('stored GPS laps must end after they start and trace times cannot be negative', () => {
    const g = storedSession();
    expect(normGpsSession(g)).not.toBeNull();
    expect(normGpsSession({ ...g, laps: [{ ...g.laps[0], endMs: g.laps[0].startMs }] })).toBeNull();
    expect(normGpsSession({ ...g, laps: [{ ...g.laps[0], startMs: -5 }] })).toBeNull();
    expect(normGpsSession({ ...g, trace: [[-1, 36.5, -121.7, 3, 4], ...g.trace.slice(1)] })).toBeNull();
  });
  it('lap accuracy in GPS analysis follows the unit setting', async () => {
    const { GpsAnalysis } = await import('../src/components/GpsAnalysis');
    const h = wrap(<GpsAnalysis gps={storedSession()} name="Test" date="2026-06-01" />, 'metric');
    expect(h).toMatch(/±(<!-- -->)?4 m/);
    const hi = wrap(<GpsAnalysis gps={storedSession()} name="Test" date="2026-06-01" />, 'imperial');
    expect(hi).toMatch(/±(<!-- -->)?13 ft/);
  });
});

describe('track map', () => {
  it('fits an equirectangular projection inside the box, keeping the aspect ratio', () => {
    const pts = [{ lat: 36.58, lon: -121.76 }, { lat: 36.59, lon: -121.74 }];
    const f = fitMap(pts, 400, 300, 10)!;
    const a = f(pts[0]), b = f(pts[1]);
    for (const p of [a, b]) { expect(p.x).toBeGreaterThanOrEqual(10 - 1e-9); expect(p.x).toBeLessThanOrEqual(390 + 1e-9); expect(p.y).toBeGreaterThanOrEqual(10 - 1e-9); expect(p.y).toBeLessThanOrEqual(290 + 1e-9); }
    expect(b.y).toBeLessThan(a.y); // north is up
    // East-west metres per north-south metre are preserved: 0.02° lon × cos(36.585°) vs 0.01° lat.
    const ratio = Math.abs(b.x - a.x) / Math.abs(b.y - a.y);
    expect(ratio).toBeCloseTo((0.02 * Math.cos((36.585 * Math.PI) / 180)) / 0.01, 3);
    expect(fitMap([], 400, 300)).toBeNull();
    const one = fitMap([pts[0]], 400, 300)!(pts[0]);
    expect(one).toEqual({ x: 200, y: 150 });
  });
  it('bins speeds into equal-width classes and finds the nearest point', () => {
    const b = speedBins([10, 20, 30, 40, 60]);
    expect(b.edges).toHaveLength(SPEED_COLORS.length + 1);
    expect(b.of(10)).toBe(0); expect(b.of(60)).toBe(SPEED_COLORS.length - 1); expect(b.of(35)).toBe(2);
    expect(speedBins([5, 5]).of(5)).toBe(0);
    expect(nearestIndex([{ x: 0, y: 0 }, { x: 10, y: 10 }], 8, 7)).toBe(1);
    expect(nearestIndex([], 1, 1)).toBe(-1);
  });
  it('slices a lap with time and distance from its start', () => {
    const g = storedSession();
    const lap = g.laps[0];
    const p = lapPoints(g.trace, lap.startMs, lap.endMs);
    expect(p.length).toBeGreaterThan(40);
    expect(p[0].ms).toBeGreaterThanOrEqual(0);
    expect(p[p.length - 1].dM).toBeGreaterThan(1800); // ≈ 2π·300 m
  });
  it('sector table: best per sector and theoretical best over valid laps only', () => {
    const t = sectorTable([
      { n: 1, seconds: 90, sectors: [30, 31, 29], valid: true },
      { n: 2, seconds: 88, sectors: [29.5, 30, 28.5], valid: true },
      { n: 3, seconds: 80, sectors: [20, 30, 30], valid: false },
      { n: 4, seconds: 91, sectors: null, valid: true },
    ]);
    expect(t.count).toBe(3);
    expect(t.rows.map((r) => r.n)).toEqual([1, 2, 3]);
    expect(t.best).toEqual([29.5, 30, 28.5]);
    expect(t.theoretical).toBe(88);
    expect(t.bestLap).toBe(88);
    expect(sectorTable([{ n: 1, seconds: 90, sectors: null, valid: true }]).count).toBe(0);
    expect(sectorTable([{ n: 1, seconds: 90, sectors: [45, 45], valid: false }]).theoretical).toBeNull();
  });
  it('renders the map, legend, lines, data table and sector table', () => {
    const h = wrap(<TrackMap gps={storedSession()} />);
    expect(h).toContain('Track map (speed)');
    expect(h).toContain('tm-sf');
    expect((h.match(/class="tm-sector"/g) ?? []).length).toBe(2);
    expect(h).toContain('spd-0');
    expect(h).toContain('Speed legend (mph)');
    expect(h).toContain('slowest');
    expect(h).toContain('Lap 1 samples');
    expect(h).toContain('Sector times (s)');
    expect(h).toContain('Theoretical best');
    expect(h).toContain('Point along the lap');
    expect(h).not.toMatch(/https?:\/\/(?!www\.w3\.org)/); // no tiles, nothing fetched
    const es1 = wrap(<TrackMap gps={storedSession()} />, 'metric', 'es');
    expect(es1).toContain('Mapa del circuito');
    expect(es1).toContain('km/h');
  });
  it('renders nothing for a trimmed (trace-less) session', () => {
    expect(wrap(<TrackMap gps={{ ...storedSession(), trace: [] }} />)).toBe('');
  });
});

/** Fake encoder: "resizes" to a JPEG-sized blob without a canvas. */
const fakeEncode = (size = 50_000): Encoder => async () => ({ blob: new Blob([new Uint8Array(size).fill(1)], { type: 'image/jpeg' }), thumb: new Blob([new Uint8Array(1000)], { type: 'image/jpeg' }), w: 1600, h: 1200 });
const img = () => new Blob([new Uint8Array(10)], { type: 'image/png' });

describe('photos', () => {
  beforeEach(() => setPhotoBackend(memoryBackend()));
  afterEach(() => setPhotoBackend(null));
  it('fits within the max size without upscaling', () => {
    expect(fitWithin(4000, 3000, 1600)).toEqual({ w: 1600, h: 1200 });
    expect(fitWithin(3000, 4000, 1600)).toEqual({ w: 1200, h: 1600 });
    expect(fitWithin(800, 600, 1600)).toEqual({ w: 800, h: 600 });
    expect(fitWithin(0, 600, 1600)).toEqual({ w: 0, h: 0 });
  });
  it('adds, lists per entry and deletes with the entry', async () => {
    const o = { kind: 'service' as const, id: 'abc123' };
    await addPhoto(o, img(), fakeEncode());
    await addPhoto({ kind: 'track', id: 'zzz' }, img(), fakeEncode());
    expect(await photosFor(o)).toHaveLength(1);
    await deletePhotosFor(o);
    expect(await photosFor(o)).toHaveLength(0);
    expect(await allPhotos()).toHaveLength(1);
  });
  it('refuses non-images, too many per entry and over the total quota with typed errors', async () => {
    const o = { kind: 'mod' as const, id: 'm1' };
    await expect(addPhoto(o, new Blob(['x'], { type: 'text/plain' }), fakeEncode())).rejects.toMatchObject({ code: 'notImage' });
    for (let i = 0; i < MAX_PER_OWNER; i++) await addPhoto(o, img(), fakeEncode());
    await expect(addPhoto(o, img(), fakeEncode())).rejects.toBeInstanceOf(PhotoError);
    await expect(addPhoto(o, img(), fakeEncode())).rejects.toMatchObject({ code: 'perEntry' });
    expect(() => checkQuota([{ kind: 'mod', ownerId: 'x', bytes: MAX_TOTAL_BYTES - 10 }], o, 100)).toThrow(PhotoError);
    await expect(addPhoto({ kind: 'mod', id: 'bad id!' }, img(), fakeEncode())).rejects.toMatchObject({ code: 'storage' });
    await expect(addPhoto(o, img(), async () => { throw new PhotoError('decode'); })).rejects.toMatchObject({ code: 'perEntry' });
    await expect(addPhoto({ kind: 'mod', id: 'm2' }, img(), async () => { throw new PhotoError('decode'); })).rejects.toMatchObject({ code: 'decode' });
  });
  it('base64 round-trips bytes and backups restore photos', async () => {
    const u8 = new Uint8Array([0xff, 0xd8, 0xff, 0, 1, 2, 250]);
    expect([...b64ToBytes(bytesToB64(u8))]).toEqual([...u8]);
    await addPhoto({ kind: 'service', id: 's1' }, img(), async () => ({ blob: new Blob([u8], { type: 'image/jpeg' }), thumb: new Blob([u8]), w: 10, h: 8 }));
    const b = await photosToBackup();
    expect(b[0].data.startsWith('/9j/')).toBe(true);
    expect(normPhotoBackup(b[0])).not.toBeNull();
    setPhotoBackend(memoryBackend());
    expect(await restorePhotos(b, async () => { throw new Error('no canvas'); })).toBe(1);
    const back = await allPhotos();
    expect(back[0].id).toBe(b[0].id);
    expect([...new Uint8Array(await back[0].blob.arrayBuffer())]).toEqual([...u8]);
  });
  it('validates backup photos strictly', () => {
    const ok = { id: 'pabc12345', kind: 'track', ownerId: 'sess1', created: '2026-06-01T10:00:00.000Z', w: 1600, h: 900, data: '/9j/AAAA' };
    expect(normPhotoBackup(ok)).not.toBeNull();
    expect(normPhotoBackup({ ...ok, data: 'iVBORw0K' })).toBeNull(); // PNG, not JPEG
    expect(normPhotoBackup({ ...ok, data: '/9j/<script>' })).toBeNull();
    expect(normPhotoBackup({ ...ok, kind: 'dyno' })).toBeNull();
    expect(normPhotoBackup({ ...ok, ownerId: '__proto__/x' })).toBeNull();
    expect(normPhotoBackup({ ...ok, w: 4000 })).toBeNull();
    expect(normPhotoBackup({ ...ok, created: 'yesterday' })).toBeNull();
    expect(normPhotoBackup({ ...ok, data: '/9j/' + 'A'.repeat(2_100_000) })).toBeNull(); // over the per-photo cap
  });
});

describe('backup v8', () => {
  const photo = (i: number, owner = 'e1') => ({ id: `pphoto${i}xx`, kind: 'service', ownerId: owner, created: '2026-06-01T10:00:00.000Z', w: 10, h: 10, data: '/9j/AAAA' });
  it('is schema 8 and migrates v7 with an empty checklist template', () => {
    expect(SCHEMA_VERSION).toBe(8);
    expect(migrate({ schema: 7 })).toMatchObject({ schema: 8, ptc: { items: [] } });
    const v7 = { ...makeBackup({ vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: [] }, [], []), schema: 7 } as Record<string, unknown>;
    delete v7.ptc;
    const r = validateBackup(v7);
    expect(r.ok && r.migratedFrom).toBe(7);
    expect(r.ok && r.data.ptc).toEqual({ items: [] });
    expect(r.ok && 'photos' in r.data).toBe(false);
  });
  it('round-trips the checklist template, per-session checklists and photos', () => {
    const track = [{ id: 't1', date: '2026-06-01', track: 'VIR', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: '1:59.1', notes: '', checklist: [{ id: 'ptc-brake-fluid', label: 'Brake fluid', done: true, kind: 'sourced' as const, factId: 'track-intervals' }] }];
    const b = makeBackup({ vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: [] }, [], track, [], [], undefined, undefined, undefined, { ptc: { items: ['Torque lugs'] }, photos: [photo(1) as never] });
    const r = parseBackup(JSON.stringify(b));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.data.ptc.items).toEqual(['Torque lugs']);
    expect(r.data.track[0].checklist?.[0].done).toBe(true);
    expect(r.data.photos).toHaveLength(1);
  });
  it('rejects malformed photos, duplicates, too many per entry and bad checklists', () => {
    const base = makeBackup({ vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: [] }, [], []);
    expect(validateBackup({ ...base, photos: [{ ...photo(1), data: 'nope' }] }).ok).toBe(false);
    expect(validateBackup({ ...base, photos: [photo(1), photo(1)] }).ok).toBe(false);
    expect(validateBackup({ ...base, photos: Array.from({ length: MAX_PER_OWNER + 1 }, (_, i) => photo(i)) }).ok).toBe(false);
    expect(validateBackup({ ...base, ptc: { items: [5] } }).ok).toBe(false);
    expect(normTrack({ id: 't', date: 'd', track: 'x', laps: '', checklist: [{ id: 'a', label: 'x', done: 'yes', kind: 'user' }] })).toBeNull();
    expect(normChecklist(Array.from({ length: 41 }, (_, i) => ({ id: `i${i}`, label: 'x', done: false, kind: 'user' })))).toBeNull();
    expect(normChecklist([{ id: 'a', label: 'x', done: false, kind: 'admin' }])).toBeNull();
  });
  it('accepts a large file only when it carries photos', () => {
    const big = 'x'.repeat(MAX_IMPORT_BYTES + 10);
    const base = makeBackup({ vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: [] }, [], []);
    const r1 = parseBackup(JSON.stringify({ ...base, pad: big }));
    expect(!r1.ok && r1.errors[0]).toMatch(/larger than 4 MB/);
    const r2 = parseBackup(JSON.stringify({ ...base, photos: [photo(1)], pad: big }));
    expect(r2.ok).toBe(true);
  });
  it('export: default has no photos; "include photos" adds them', async () => {
    const plain = await buildExport(false, async () => { throw new Error('must not read photos'); });
    expect(plain.ok && JSON.parse(plain.text).photos).toBeUndefined();
    const withP = await buildExport(true, async () => [photo(1) as never]);
    expect(withP.ok && withP.photos).toBe(1);
    expect(withP.ok && parseBackup(withP.text).ok).toBe(true);
    const fail = await buildExport(true, async () => { throw new Error('idb'); });
    expect(fail).toEqual({ ok: false, error: 'photos' });
  });
});

describe('pre-track checklist', () => {
  beforeEach(() => store.clear());
  it('sourced items point at real maintenance records', () => {
    for (const c of SOURCED_CHECKS) {
      const f = factFor(c.factId);
      expect(f, c.factId).toBeTruthy();
      expect(f!.source).toMatch(/^https:\/\//);
    }
    expect(factFor('track-intervals')!.value).toMatch(/DOT 4 LV/);
  });
  it('tire pressures stay an owner field until a pressure is sourced', () => {
    expect(tirePressuresSourced()).toBe(false);
    const l = freshChecklist((k) => translate('en', k));
    expect(l.find((x) => x.id === 'ptc-tires')?.label).toBe(en['ptc.tiresOwn']);
    expect(l.filter((x) => x.kind === 'sourced')).toHaveLength(SOURCED_CHECKS.length);
  });
  it('owner items come from the template and are normalised', () => {
    store.set(PTC_KEY, JSON.stringify({ items: ['  Torque lugs ', '', 'x'.repeat(300)] }));
    expect(loadPtc().items).toEqual(['Torque lugs', 'x'.repeat(120)]);
    expect(normPtc({ items: 'no' })).toBeNull();
    const l = freshChecklist((k) => translate('es', k));
    expect(l.some((x) => x.label === 'Torque lugs')).toBe(true);
    expect(l[0].label).toBe(es['ptc.brakeFluid']);
  });
  it('renders the checklist with citations and the saved copy', () => {
    const items = freshChecklist((k) => translate('en', k));
    const h = wrap(<PreTrackChecklist items={items} onChange={() => undefined} />);
    expect(h).toContain('Pre-track checklist');
    expect(h).toContain('DOT 4 LV');
    expect(h).toContain('badge-reported');
    expect(h).toContain('No Ford-sourced GT500 track pressure');
    const s = wrap(<SavedChecklist items={[{ ...items[0], done: true }, items[1]]} />);
    expect(s).toContain('1 of 2 done');
  });
});

describe('car-color accent', () => {
  it('meets WCAG AA for every chromatic paint, in both themes, or falls back', () => {
    for (const c of colors) for (const theme of ['dark', 'light'] as const) {
      const a = deriveAccent(c.swatch, theme);
      if (!a) continue;
      for (const bg of THEME_BGS[theme]) expect(contrast(hexToRgb(a.accent)!, hexToRgb(bg)!), `${c.id} ${theme}`).toBeGreaterThanOrEqual(AA);
      expect(contrast(hexToRgb(a.accentBtn)!, [255, 255, 255])).toBeGreaterThanOrEqual(AA);
    }
    expect(deriveAccent('#d0121b', 'dark')).not.toBeNull();
    expect(deriveAccent('#d0121b', 'light')).not.toBeNull();
    expect(deriveAccent('#9ccc2a', 'light')).not.toBeNull(); // light lime is darkened, not rejected
  });
  it('falls back for neutral, missing or malformed colours', () => {
    expect(deriveAccent('#111214', 'dark')).toBeNull();
    expect(deriveAccent('#b9bcbf', 'light')).toBeNull();
    expect(deriveAccent(null, 'dark')).toBeNull();
    expect(deriveAccent('red', 'dark')).toBeNull();
  });
  it('is off unless chosen', () => {
    expect(normalizeSettings({}).accent).toBe('default');
    expect(normalizeSettings({ accent: 'car' }).accent).toBe('car');
    expect(normalizeSettings({ accent: 'javascript:' }).accent).toBe('default');
  });
});

describe('startFinishLines data slot', () => {
  const line = (o: Partial<StartFinishLine> = {}): StartFinishLine => ({
    id: 'laguna-gp', trackId: 'weathertech-raceway-laguna-seca', configuration: 'Grand Prix Circuit', a: { lat: 36.58706, lon: -121.75370 }, b: { lat: 36.58720, lon: -121.75355 },
    sectors: [], source: 'https://www.openstreetmap.org/way/123', confidence: 'unverified', ...o,
  });
  it('holds the OSM lines, has a schema, may be empty, and shows on Coverage', () => {
    expect(startFinishLines).toHaveLength(9);
    expect(SCHEMAS.startFinishLines).toBeTruthy();
    expect(MAY_BE_EMPTY.has('startFinishLines')).toBe(true);
    expect(readFileSync('schemas/startFinishLines.schema.json', 'utf8')).toBe(JSON.stringify(SCHEMAS.startFinishLines, null, 2) + '\n');
    expect(computeCoverage(collections).sections.find((s) => s.name === 'startFinishLines')?.records).toBe(9);
    expect(routeFor('startFinishLines', {})).toBe('/laptimer');
  });
  it('checks track links, duplicates, line length and distance from the facility', () => {
    const run = (lines: StartFinishLine[]) => checkCollections({ tracks: tracks as unknown as Sourced[], startFinishLines: lines as unknown as Sourced[] });
    expect(run([line()])).toEqual([]);
    expect(run([line({ trackId: 'nope' })]).map((i) => i.message).join()).toMatch(/unknown track id/);
    expect(run([line(), line({ id: 'x2', configuration: 'grand prix circuit' })]).map((i) => i.message).join()).toMatch(/same track and configuration/);
    expect(run([line({ b: { lat: 36.6, lon: -121.75 } })]).map((i) => i.message).join()).toMatch(/m long/);
    expect(run([line({ a: { lat: 37.5, lon: -121.75 }, b: { lat: 37.5001, lon: -121.75 } })]).map((i) => i.message).join()).toMatch(/km from the track/);
    expect(run([line({ source: 'http://x' } as never)]).length).toBeGreaterThan(0);
    expect(run([line({ extra: 1 } as never)]).map((i) => i.message).join()).toMatch(/unknown field/);
  });
  it('lap-timer helpers: lines per track/configuration, timing lines, OSM detection', () => {
    expect(linesForTrack([line()], 'weathertech-raceway-laguna-seca')).toHaveLength(1);
    expect(linesForTrack([line()], 'weathertech-raceway-laguna-seca', 'GRAND PRIX CIRCUIT')).toHaveLength(1);
    expect(linesForTrack([line()], 'road-america')).toHaveLength(0);
    expect(sourcedTimingLines(line()).line.dir).toBe(0);
    expect(sourcedTimingLines(line({ direction: -1, sectors: [{ a: { lat: 1, lon: 1 }, b: { lat: 1, lon: 1.0001 } }] }))).toMatchObject({ line: { dir: -1 }, sectors: [{ dir: 0 }] });
    expect(isOsmSource('https://www.openstreetmap.org/way/1')).toBe(true);
    expect(isOsmSource('https://osm.org/go/x')).toBe(true);
    expect(isOsmSource('https://notopenstreetmap.org.evil.com/')).toBe(false);
    expect(isOsmSource('not a url')).toBe(false);
  });
  it('"Use sourced line" appears only when a line exists, with source, confidence and OSM credit', () => {
    const none = wrap(<SourcedLinePicker trackId="weathertech-raceway-laguna-seca" lines={[]} onUse={() => undefined} />);
    expect(none).not.toContain('Use sourced line');
    expect(none).toContain('No sourced start/finish line');
    expect(wrap(<SourcedLinePicker trackId="" lines={[line()]} onUse={() => undefined} />)).toBe('');
    const osm = wrap(<SourcedLinePicker trackId="weathertech-raceway-laguna-seca" lines={[line()]} onUse={() => undefined} />);
    expect(osm).toContain('Use sourced line');
    expect(osm).toContain('badge-unverified');
    expect(osm).toContain('© OpenStreetMap contributors');
    const doc = wrap(<SourcedLinePicker trackId="weathertech-raceway-laguna-seca" lines={[line({ source: 'https://www.weathertechraceway.com/track-map' })]} onUse={() => undefined} />);
    expect(doc).toContain('Use sourced line');
    expect(doc).not.toContain('OpenStreetMap');
  });
});
