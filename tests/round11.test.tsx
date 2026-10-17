import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import {
  MAX_TRACE_POINTS, MIN_LAP_MS, bestLap, buildLaps, detectCrossings, downsample, fmtLap, ghostDelta, lapProfile, lapSpeedTrace, lineFromHeading,
  lineFromPoints, liveState, nearestFacility, projector, pruneTraces, radialLine, segmentIntersect, sessionFromFixes, smoothFixes, syntheticCircuit,
  toGpx, toTrace, traceCsv,
} from '../src/lib/lapTimer';
import type { Fix } from '../src/lib/gps';
import { parseLaps } from '../src/lib/laptime';
import { normGpsSession, normTrack } from '../src/lib/validate';
import { MAX_IMPORT_BYTES, SCHEMA_VERSION, makeBackup, migrate, validateBackup } from '../src/lib/backup';
import { fetchWeather, normWeatherPrefs, parseCoords, parseWeather, weatherUrl, WEATHER_ORIGIN } from '../src/lib/weather';
import { compact, editDistance, groupHits, loadRecent, norm, pushRecent, rankedSearch, search } from '../src/lib/search';
import { archivedUrl, computeCoverage, hostOf } from '../src/lib/coverage';
import { factRows, toCsv } from '../src/lib/factExport';
import { collections } from '../src/data';
import { tracks } from '../src/data/tracks';
import { competitors } from '../src/data/competitors';
import { events, milestones } from '../src/data/history';
import { SCHEMAS, checkCollections, validateSchema } from '../src/lib/dataSchema';
import { Src } from '../src/components/Facts';
import { GpsAnalysis } from '../src/components/GpsAnalysis';
import LapTimer from '../src/pages/LapTimer';
import Search from '../src/pages/Search';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import { readFileSync } from 'node:fs';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });

const wrap = (el: JSX.Element) => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS }, setSettings: () => undefined }}>
    <MemoryRouter>{el}</MemoryRouter>
  </SettingsContext.Provider>,
);

const LAP_S = (2 * Math.PI * 300) / 40; // 47.124 s for the default synthetic circuit
const SOUTH = -Math.PI / 2;

describe('lap timer geometry', () => {
  it('intersects segments and reports the crossing side', () => {
    const q1 = { x: 0, y: -10 }, q2 = { x: 0, y: 10 };
    const a = segmentIntersect({ x: -5, y: 0 }, { x: 5, y: 0 }, q1, q2);
    const b = segmentIntersect({ x: 5, y: 0 }, { x: -5, y: 0 }, q1, q2);
    expect(a?.u).toBeCloseTo(0.5);
    expect(a && b && a.side === -b.side).toBe(true);
    expect(segmentIntersect({ x: -5, y: 20 }, { x: 5, y: 20 }, q1, q2)).toBeNull(); // misses the line's end
    expect(segmentIntersect({ x: -5, y: 0 }, { x: -5, y: 5 }, q1, q2)).toBeNull(); // parallel
    expect(segmentIntersect({ x: -5, y: 0 }, { x: -1, y: 0 }, q1, q2)).toBeNull(); // stops short
  });
  it('projects round-trip within millimetres', () => {
    const P = projector({ lat: 36.58, lon: -121.75 });
    const p = P.toLatLon(P.toXY({ lat: 36.585, lon: -121.749 }));
    expect(p.lat).toBeCloseTo(36.585, 8); expect(p.lon).toBeCloseTo(-121.749, 8);
  });
  it('smoothing keeps time and ends, and damps a single outlier', () => {
    const f = syntheticCircuit({ laps: 0.2 });
    const bad = f.map((x, i) => (i === 3 ? { ...x, lat: x.lat + 0.0005 } : x));
    const s = smoothFixes(bad);
    expect(s.map((x) => x.t)).toEqual(bad.map((x) => x.t));
    expect(s[0]).toEqual(bad[0]);
    expect(Math.abs(s[3].lat - f[3].lat)).toBeLessThan(Math.abs(bad[3].lat - f[3].lat));
  });
});

describe('lap detection on synthetic circuits', () => {
  it('times clean laps with sub-fix interpolation at 1 Hz', () => {
    const laps = buildLaps(syntheticCircuit({ laps: 3.2 }), radialLine(SOUTH));
    expect(laps).toHaveLength(2);
    for (const l of laps) { expect(l.valid).toBe(true); expect(l.seconds).toBeCloseTo(LAP_S, 1); }
  });
  it('1 Hz and 10 Hz agree within 50 ms', () => {
    const a = buildLaps(syntheticCircuit({ laps: 2.2, hz: 1 }), radialLine(SOUTH));
    const b = buildLaps(syntheticCircuit({ laps: 2.2, hz: 10 }), radialLine(SOUTH));
    expect(Math.abs(a[0].seconds - b[0].seconds)).toBeLessThan(0.05);
  });
  it('tolerates position jitter without phantom laps', () => {
    const laps = buildLaps(syntheticCircuit({ laps: 4.2, jitterM: 3 }), radialLine(SOUTH));
    expect(laps).toHaveLength(3);
    for (const l of laps) expect(Math.abs(l.seconds - LAP_S)).toBeLessThan(0.4);
  });
  it('filters by direction', () => {
    const fx = syntheticCircuit({ laps: 2.2 });
    const auto = detectCrossings(fx, radialLine(SOUTH));
    expect(auto.length).toBe(2);
    const side = auto[0].side;
    expect(detectCrossings(fx, radialLine(SOUTH, { dir: side })).length).toBe(2);
    expect(detectCrossings(fx, radialLine(SOUTH, { dir: side === 1 ? -1 : 1 })).length).toBe(0);
    // Driving the other way round never counts against a line locked to the first direction.
    expect(detectCrossings(syntheticCircuit({ laps: 2.2, clockwise: true }), radialLine(SOUTH, { dir: side })).length).toBe(0);
  });
  it('ignores jitter back and forth across the line (debounce)', () => {
    const line = radialLine(SOUTH);
    const P = projector({ lat: 36.584, lon: -121.753 });
    const fx: Fix[] = Array.from({ length: 20 }, (_, i) => {
      const p = P.toLatLon({ x: i % 2 ? 2 : -2, y: -300 });
      return { t: 1e12 + i * 1000, lat: p.lat, lon: p.lon, accuracy: 3, speed: 0 };
    });
    const xs = detectCrossings(fx, { ...line, dir: 0 }, { smooth: false });
    expect(xs.length).toBe(1);
    expect(MIN_LAP_MS).toBeGreaterThan(10_000);
  });
  it('refuses laps with GPS gaps', () => {
    const fx = syntheticCircuit({ laps: 3.2 });
    const t1 = fx[0].t + (LAP_S * 1.5) * 1000;
    const gappy = fx.filter((f) => f.t < t1 || f.t > t1 + 5000);
    const laps = buildLaps(gappy, radialLine(SOUTH));
    expect(laps.map((l) => l.valid)).toEqual([false, true]);
    expect(laps[0].reason).toBe('gap');
  });
  it('refuses laps with poor accuracy', () => {
    const fx = syntheticCircuit({ laps: 3.2 }).map((f, i) => (i === 80 ? { ...f, accuracy: 25 } : f));
    const laps = buildLaps(fx, radialLine(SOUTH));
    expect(laps.some((l) => !l.valid && l.reason === 'accuracy')).toBe(true);
    expect(bestLap(laps)?.valid).toBe(true);
  });
  it('splits sectors that add up to the lap', () => {
    const laps = buildLaps(syntheticCircuit({ laps: 2.2 }), radialLine(SOUTH), { sectors: [radialLine(Math.PI / 6), radialLine((5 * Math.PI) / 6)] });
    const s = laps[0].sectors;
    expect(s).toHaveLength(3);
    expect(s!.reduce((a, b) => a + b, 0)).toBeCloseTo(laps[0].seconds, 6);
  });
  it('ghost delta: 0 against itself, positive when slower', () => {
    const fx = syntheticCircuit({ laps: 2.2 });
    const lap = buildLaps(fx, radialLine(SOUTH))[0];
    const p = lapProfile(fx, lap);
    expect(ghostDelta(p, 500, p.s[p.d.findIndex((d) => d >= 500)] ?? 0)).toBeLessThan(1.5);
    expect(ghostDelta(p, 500, 30)!).toBeGreaterThan(10);
    expect(ghostDelta(p, 1e9, 10)).toBeNull();
  });
  it('live state counts laps and shows a delta on later laps', () => {
    const fx = syntheticCircuit({ laps: 3.5 });
    const s = liveState(fx, radialLine(SOUTH));
    expect(s.lapNo).toBe(3);
    expect(s.best).not.toBeNull();
    expect(Math.abs(s.deltaS ?? 99)).toBeLessThan(1.5);
  });
  it('drops a line from the direction of travel that counts only that direction', () => {
    const fx = syntheticCircuit({ laps: 2.5 });
    const l = lineFromHeading(fx[10], fx[11])!;
    expect(l.dir).not.toBe(0);
    expect(buildLaps(fx, l).length).toBe(2);
    expect(detectCrossings(fx, { ...l, dir: (l.dir === 1 ? -1 : 1) }).length).toBe(0);
    expect(lineFromHeading(fx[10], fx[10])).toBeNull();
  });
  it('lineFromPoints defaults to "first crossing decides"', () => {
    expect(lineFromPoints({ lat: 1, lon: 2 }, { lat: 1, lon: 3 }).dir).toBe(0);
  });
});

describe('stored sessions', () => {
  it('downsamples to a cap keeping endpoints', () => {
    const xs = Array.from({ length: 10000 }, (_, i) => i);
    const d = downsample(xs, 100);
    expect(d).toHaveLength(100); expect(d[0]).toBe(0); expect(d[99]).toBe(9999);
  });
  it('builds a capped, valid session and Track-log text', () => {
    const fx = syntheticCircuit({ laps: 60, hz: 1 }); // ~2800 fixes > cap
    const s = sessionFromFixes(fx, radialLine(SOUTH), [])!;
    expect(s.gps.trace.length).toBe(MAX_TRACE_POINTS);
    expect(parseLaps(s.text).laps.length).toBe(s.laps.filter((l) => l.valid).length);
    expect(normGpsSession(s.gps)).not.toBeNull();
    expect(fmtLap(LAP_S)).toBe('0:47.124');
  });
  it('speed trace per lap', () => {
    const fx = syntheticCircuit({ laps: 2.2 });
    const s = sessionFromFixes(fx, radialLine(SOUTH), [])!;
    const tr = lapSpeedTrace(s.gps.trace, s.gps.laps[0].startMs, s.gps.laps[0].endMs);
    expect(tr.length).toBeGreaterThan(40);
    expect(tr[tr.length - 1].dM).toBeGreaterThan(1800);
    expect(tr.every((p) => Math.abs(p.mps - 40) < 0.1)).toBe(true);
  });
  it('rejects malformed or oversized GPS data', () => {
    const s = sessionFromFixes(syntheticCircuit({ laps: 2.2 }), radialLine(SOUTH), [])!;
    expect(normGpsSession({ ...s.gps, trace: Array.from({ length: MAX_TRACE_POINTS + 1 }, () => [0, 1, 1, 1, 1]) })).toBeNull();
    expect(normGpsSession({ ...s.gps, line: { a: { lat: 91, lon: 0 }, b: { lat: 0, lon: 0 }, dir: 0 } })).toBeNull();
    expect(normGpsSession({ ...s.gps, trace: [[0, 1, 1, -1, 1]] })).toBeNull();
    expect(normGpsSession({ ...s.gps, laps: [{ n: 1, seconds: -1, sectors: null, accuracyM: 1, startMs: 0, endMs: 1, valid: true }] })).toBeNull();
    const base = { id: 'a', date: '2026-01-01', track: 'X', laps: '' };
    expect(normTrack({ ...base, gps: 'nope' })).toBeNull();
    expect(normTrack({ ...base, gps: s.gps })?.gps?.laps.length).toBe(1);
  });
  it('backup v7 round-trips GPS sessions; v6 migrates', () => {
    expect(SCHEMA_VERSION).toBe(9);
    expect(MAX_IMPORT_BYTES).toBe(4 * 1024 * 1024);
    const s = sessionFromFixes(syntheticCircuit({ laps: 2.2 }), radialLine(SOUTH), [])!;
    const track = [{ id: 't', date: '2026-01-01', track: 'X', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: s.text, notes: '', gps: s.gps }];
    const r = validateBackup(JSON.parse(JSON.stringify(makeBackup({ vin: '', year: '', color: '', nickname: '', odometer: '', mods: [], service: [], reminders: [] }, [], track))));
    expect(r.ok && r.data.track[0].gps?.trace.length).toBe(s.gps.trace.length);
    expect(migrate({ schema: 6 })).toMatchObject({ schema: 9 });
  });
  it('prunes old traces but keeps laps', () => {
    const s = sessionFromFixes(syntheticCircuit({ laps: 1.2 }), radialLine(SOUTH), [])!;
    const list = Array.from({ length: 4 }, (_, i) => ({ date: '2026', gps: { ...s.gps, startIso: `2026-01-0${i + 1}` } }));
    const p = pruneTraces(list, 2);
    expect(p.filter((x) => x.gps.trace.length).map((x) => x.gps.startIso)).toEqual(['2026-01-03', '2026-01-04']);
    expect(p.every((x) => x.gps.laps.length === s.gps.laps.length)).toBe(true);
  });
  it('exports GPX (escaped) and CSV', () => {
    const tr = toTrace(syntheticCircuit({ laps: 0.1 }));
    const g = toGpx('A <b> & "c"', '2026-01-01T00:00:00.000Z', tr);
    expect(g).toContain('<name>A &lt;b&gt; &amp; &quot;c&quot;</name>');
    expect(g).toContain('<time>2026-01-01T00:00:00.000Z</time>');
    expect((g.match(/<trkpt /g) ?? []).length).toBe(tr.length);
    const c = traceCsv(tr, [{ n: 1, startMs: 0, endMs: 2000 }]).split('\r\n');
    expect(c[0]).toBe('t_ms,lap,lat,lon,speed_mps,accuracy_m');
    expect(c[1].split(',')[1]).toBe('1');
  });
  it('renders the analysis with min/max and export buttons', () => {
    const s = sessionFromFixes(syntheticCircuit({ laps: 2.2 }), radialLine(SOUTH), [])!;
    const h = wrap(<GpsAnalysis gps={s.gps} name="Test" date="2026-01-01" />);
    for (const x of ['Speed vs distance', 'Export CSV', 'Export GPX', 'Max']) expect(h).toContain(x);
    expect(wrap(<GpsAnalysis gps={{ ...s.gps, trace: [] }} name="T" date="d" />)).toContain('trimmed');
  });
});

describe('tracks data slot', () => {
  it('has 29 sourced facilities and never a start/finish line from a centroid', () => {
    expect(tracks).toHaveLength(29);
    expect(tracks.every((t) => t.startFinish === null && t.sectors.length === 0)).toBe(true);
    expect(tracks.filter((t) => !t.facility).map((t) => t.id)).toEqual(['zmax-dragway']);
    expect(checkCollections({ tracks })).toEqual([]);
  });
  it('schema rejects bad coordinates and unknown fields', () => {
    const t = tracks[0];
    expect(validateSchema(SCHEMAS.tracks, [{ ...t, facility: { lat: 100, lon: 0 } }]).length).toBeGreaterThan(0);
    expect(validateSchema(SCHEMAS.tracks, [{ ...t, startFinish: { a: { lat: 1, lon: 1 } } }]).length).toBeGreaterThan(0);
    expect(validateSchema(SCHEMAS.tracks, [{ ...t, foo: 1 }]).length).toBeGreaterThan(0);
    expect(checkCollections({ ...collections }).filter((i) => i.collection === 'tracks')).toEqual([]);
  });
  it('nearest facility is a hint within range only', () => {
    const lag = tracks.find((t) => t.id.includes('laguna'))!;
    expect(nearestFacility({ lat: lag.facility!.lat + 0.005, lon: lag.facility!.lon }, tracks)?.track.id).toBe(lag.id);
    expect(nearestFacility({ lat: 0, lon: 0 }, tracks)).toBeNull();
  });
  it('coverage includes tracks and routes them to the lap timer', () => {
    const c = computeCoverage(collections);
    expect(c.sections.find((s) => s.name === 'tracks')?.records).toBe(29);
    expect(c.gaps.some((g) => g.collection === 'tracks' && g.route === '/laptimer')).toBe(true);
  });
});

describe('round 9 data', () => {
  it('competitor MSRPs with model year, destination flag and conflicts', () => {
    const by = (id: string) => competitors.find((c) => c.id === id)!.sheet!.msrp!;
    expect(by('z06')).toMatchObject({ value: 106395, modelYear: 2023, destinationIncluded: true });
    expect(by('superstock').conflicts?.[0].value).toBe(80750);
    expect(by('911s')).toMatchObject({ value: 113300, destinationIncluded: false });
    expect(by('gt3').value).toBe(161100);
  });
  it('Track Attack end and BDC winner are recorded, placement stays null', () => {
    expect(events.find((e) => e.id === 'track-attack-end')?.confidence).toBe('reported');
    const w = milestones.find((m) => m.id === 'mt-bdc-2020-winner')!;
    expect(w.title).toContain('718 Cayman GT4');
    expect(w.placement).toBeNull();
  });
});

describe('weather auto-fill', () => {
  const fixture = { latitude: 36.58, longitude: -121.75, elevation: 75, current_units: { temperature_2m: '°F' }, current: { time: '2026-06-01T12:00', temperature_2m: 68.4, relative_humidity_2m: 55, surface_pressure: 1003.2, pressure_msl: 1012.4 } };
  it('parses a response', () => {
    const w = parseWeather(fixture)!;
    expect(w).toMatchObject({ tempF: 68.4, humidity: 55, elevationFt: 246, time: '2026-06-01T12:00' });
    expect(w.stationInHg).toBeCloseTo(29.62, 2);
    expect(w.mslInHg).toBeCloseTo(29.9, 1);
  });
  it('converts °C and rejects bad responses', () => {
    expect(parseWeather({ ...fixture, current_units: { temperature_2m: '°C' }, current: { ...fixture.current, temperature_2m: 20 } })?.tempF).toBe(68);
    expect(parseWeather({})).toBeNull();
    expect(parseWeather(null)).toBeNull();
    expect(parseWeather({ current: { ...fixture.current, relative_humidity_2m: 140 } })).toBeNull();
    expect(parseWeather({ current: { ...fixture.current, surface_pressure: 'x' } })).toBeNull();
    expect(parseWeather({ current: { ...fixture.current, pressure_msl: null } })?.mslInHg).toBeNull();
  });
  it('builds the URL on the single allowed origin with rounded coordinates', () => {
    const u = weatherUrl(36.58416, -121.75361);
    expect(u.startsWith(`${WEATHER_ORIGIN}/v1/forecast?`)).toBe(true);
    expect(u).toContain('latitude=36.58'); expect(u).toContain('longitude=-121.75');
    expect(u).not.toContain('36.584');
    const csp = readFileSync('index.html', 'utf8');
    expect(csp).toMatch(/connect-src 'self' https:\/\/api\.open-meteo\.com;/);
  });
  it('fetches through an injected fetch (no live network)', async () => {
    const ok = (body: unknown, status = 200) => (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;
    expect(await fetchWeather(1, 2, ok(fixture))).toMatchObject({ ok: true });
    expect(await fetchWeather(1, 2, ok({}, 500))).toEqual({ ok: false, error: 'network' });
    expect(await fetchWeather(1, 2, ok({ nope: 1 }))).toEqual({ ok: false, error: 'bad-response' });
    expect(await fetchWeather(1, 2, (async () => { throw new Error('x'); }) as unknown as typeof fetch)).toEqual({ ok: false, error: 'network' });
  });
  it('parses coordinates and prefs defensively', () => {
    expect(parseCoords('36,58', '-121.75')).toEqual({ lat: 36.58, lon: -121.75 });
    expect(parseCoords('', '1')).toBeNull();
    expect(parseCoords('91', '0')).toBeNull();
    expect(normWeatherPrefs({ enabled: 'yes', lat: 5 })).toEqual({ enabled: false, lat: '', lon: '' });
  });
});

describe('fuzzy search', () => {
  beforeEach(() => localStorage.clear());
  it('normalizes diacritics, dashes and spacing', () => {
    expect(norm('Café – Ñ')).toBe('cafe - n');
    expect(compact('FL-2087')).toBe(compact('fl 2087'));
    expect(editDistance('whiple', 'whipple')).toBe(1);
    expect(editDistance('teh', 'the')).toBe(1);
    expect(editDistance('abcdef', 'uvwxyz', 2)).toBe(3);
  });
  it('finds part numbers in every dash/space variant', () => {
    for (const q of ['FL-2087', 'FL2087', 'fl 2087', 'FL–2087']) expect(search(q).some((h) => h.route === '/parts'), q).toBe(true);
  });
  it('tolerates typos and ranks title matches first', () => {
    expect(search('whiple').length).toBeGreaterThan(0);
    expect(rankedSearch('lap timr')[0].title).toBe('GPS Lap Timer');
    expect(rankedSearch('Density altitude')[0].title).toBe('Density altitude calculator');
    expect(search('Laguna Séca').length).toBeGreaterThan(0);
    expect(search('zzqqxx')).toEqual([]);
  });
  it('groups results and remembers recent searches (deduped)', () => {
    const g = groupHits(rankedSearch('GT500'));
    expect(new Set(g.map((x) => x.collection)).size).toBe(g.length);
    pushRecent('Whipple'); pushRecent('café'); pushRecent('CAFE');
    expect(loadRecent()).toEqual(['CAFE', 'Whipple']);
    pushRecent('x');
    expect(loadRecent()).toHaveLength(2);
  });
  it('does not index archive URLs as text', () => {
    expect(search('web.archive.org').length).toBe(0);
  });
  it('renders the search page', () => {
    expect(wrap(<Search />)).toContain('search-input');
  });
});

describe('archived (originalUrl) sources', () => {
  const wb = 'https://web.archive.org/web/20240528083635/https://www.musclecarsandtrucks.com/x/';
  it('credits the archived site, not web.archive.org', () => {
    expect(archivedUrl(wb)).toBe('https://www.musclecarsandtrucks.com/x/');
    expect(hostOf(wb)).toBe('musclecarsandtrucks.com');
    expect(hostOf('https://www.ford.com/a')).toBe('ford.com');
    const h = renderToString(<Src url={wb} />);
    expect(h).toContain('musclecarsandtrucks.com');
    expect(h).toContain('archived');
    expect(h).toContain(`href="${wb}"`);
  });
  it('fact export has an originalUrl column and keeps it out of the value', () => {
    const rows = factRows();
    const arch = rows.filter((r) => r.originalUrl);
    expect(arch.length).toBeGreaterThan(0);
    expect(arch.every((r) => r.source.endsWith(r.originalUrl) && !r.value.includes('originalUrl'))).toBe(true);
    expect(toCsv(rows.slice(0, 1)).split('\r\n')[0]).toContain(',originalUrl,');
  });
  it('coverage domains do not lump archives under web.archive.org', () => {
    expect(computeCoverage(collections).domains.some((d) => d.host === 'web.archive.org')).toBe(false);
  });
});

describe('lap timer page and i18n', () => {
  it('renders idle without starting GPS', () => {
    const h = wrap(<LapTimer />);
    expect(h).toContain('GPS Lap Timer');
    expect(h).toContain('Start GPS');
  });
  it('every new key exists in Spanish', () => {
    for (const k of Object.keys(en).filter((k) => /^(lt|ga|wx|search|src|cmp)\./.test(k) || k === 'nav.laptimer')) expect(es[k as keyof typeof es], k).toBeTruthy();
  });
});
