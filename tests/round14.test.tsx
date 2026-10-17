import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { readFileSync } from 'node:fs';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { startFinishLines } from '../src/data/startFinishLines';
import { specs } from '../src/data/specs';
import { esOverlay, specText } from '../src/data/es';
import {
  applyDirPref, buildLaps, normDirPrefs, projector, segmentIntersect, sourcedTimingLines, SFL_DIR_KEY, type LatLon, type TimingLine,
} from '../src/lib/lapTimer';
import type { Fix } from '../src/lib/gps';
import { ObdClient, cleanResponse, fakeTransport, parseDtcs, readPidValue } from '../src/lib/obd';
import { connectBle, type Bluetooth } from '../src/lib/obdBle';
import { classify, normResult, schedule } from '../src/lib/tree';
import { ask } from '../src/lib/ask';
import { loadTrackDays, normTrackDay, TRACKDAYS_KEY } from '../src/lib/trackdays';
import { ALL_KEYS, makeBackup, validateBackup } from '../src/lib/backup';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { DIAG_KEY, MAX_DIAG, clearDiag, diagExport, diagLog, loadDiag, resetDiagCache, setDiagEnabled, summarizeDiag, flushDiag } from '../src/lib/diag';
import { en } from '../src/lib/i18n';
import { es } from '../src/lib/i18n-es';
import Specs from '../src/pages/Specs';
import Diagnostics from '../src/pages/Diagnostics';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); }, clear: () => store.clear() });

const wrap = (el: JSX.Element, lang: 'en' | 'es' = 'en') => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS, lang }, setSettings: () => undefined }}><MemoryRouter>{el}</MemoryRouter></SettingsContext.Provider>,
);

/* ---------- 1. direction-sign audit ---------- */

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180, deg = (r: number) => (r * 180) / Math.PI;
/** Great-circle destination (the derivation the data file documents). */
function dest(p: LatLon, bearingDeg: number, m: number): LatLon {
  const d = m / R, b = rad(bearingDeg), f1 = rad(p.lat), l1 = rad(p.lon);
  const f2 = Math.asin(Math.sin(f1) * Math.cos(d) + Math.cos(f1) * Math.sin(d) * Math.cos(b));
  const l2 = l1 + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(f1), Math.cos(d) - Math.sin(f1) * Math.sin(f2));
  return { lat: deg(f2), lon: deg(l2) };
}
/** Parse the documented node position and way bearing out of a record's derivation note. */
function derivation(note: string) {
  const node = /at (-?[\d.]+), (-?[\d.]+) lies on/.exec(note);
  const brg = /Bearing of the way between neighbor nodes \d+ and \d+ = ([\d.]+) deg/.exec(note);
  return node && brg ? { node: { lat: Number(node[1]), lon: Number(node[2]) }, bearing: Number(brg[1]) } : null;
}

/**
 * A 300 m-radius loop that passes through the gate midpoint heading along `bearing` (sign +1) or the reverse (−1),
 * driven 2.4 times at 40 m/s, 1 Hz, ±4 m — so a working gate gives two full laps of ~47 s.
 */
function loopThrough(mid: LatLon, bearingDeg: number, sign: 1 | -1): Fix[] {
  const P = projector(mid);
  const b = rad(bearingDeg);
  const h = { x: sign * Math.sin(b), y: sign * Math.cos(b) }; // travel direction at the gate (east, north)
  const left = { x: -h.y, y: h.x };
  const r = 300, mps = 40;
  const c = { x: left.x * r, y: left.y * r }; // turning left: centre on the left
  const th0 = Math.atan2(-left.y, -left.x);
  const out: Fix[] = [];
  const n = Math.ceil((2.4 * 2 * Math.PI * r) / mps);
  for (let i = 0; i <= n; i++) {
    // Start 5 s before the gate so the first crossing is inside the trace.
    const th = th0 + ((i - 5) * mps) / r;
    out.push({ t: 1_700_000_000_000 + i * 1000, ...P.toLatLon({ x: c.x + r * Math.cos(th), y: c.y + r * Math.sin(th) }), accuracy: 4, speed: mps });
  }
  return out;
}
const mid = (l: { a: LatLon; b: LatLon }) => ({ lat: (l.a.lat + l.b.lat) / 2, lon: (l.a.lon + l.b.lon) / 2 });
const validLaps = (fixes: Fix[], line: TimingLine) => buildLaps(fixes, line).filter((l) => l.valid);

describe('direction-sign audit of every OSM start/finish line', () => {
  it('the stored gate endpoints match the documented derivation (node ± 10 m perpendicular, a on the left)', () => {
    for (const l of startFinishLines) {
      const d = derivation(l.note ?? '');
      expect(d, l.id).not.toBeNull();
      const P = projector(d!.node);
      const close = (p: LatLon, q: LatLon) => Math.hypot(P.toXY(p).x - P.toXY(q).x, P.toXY(p).y - P.toXY(q).y);
      // a = bearing − 90° (left of travel along the way), b = bearing + 90° (right).
      expect(close(l.a, dest(d!.node, (d!.bearing + 270) % 360, 10)), l.id).toBeLessThan(0.1);
      expect(close(l.b, dest(d!.node, (d!.bearing + 90) % 360, 10)), l.id).toBeLessThan(0.1);
    }
  });

  it('independently: with a on the left, travel along the bearing crosses right → left of a→b, which the timer calls +1', () => {
    // The car approaches from behind the line. Behind = right-hand side of the vector a→b when a is on the left.
    const a = { x: -10, y: 0 }, b = { x: 10, y: 0 }; // heading north (+y): a is west = left
    expect(segmentIntersect({ x: 0, y: -5 }, { x: 0, y: 5 }, a, b)?.side).toBe(1);
    expect(segmentIntersect({ x: 0, y: 5 }, { x: 0, y: -5 }, a, b)?.side).toBe(-1);
  });

  it.each(startFinishLines.map((l) => [l.id, l] as const))('%s: driving the documented bearing registers laps; the reverse is refused', (_id, l) => {
    const d = derivation(l.note ?? '')!;
    const { line } = sourcedTimingLines(l);
    const fwd = loopThrough(mid(l), d.bearing, 1), rev = loopThrough(mid(l), d.bearing, -1);
    if (l.direction) {
      expect(l.direction).toBe(1); // every directional record is documented as "travel along the way bearing"
      expect(validLaps(fwd, line).length).toBe(2);
      expect(validLaps(rev, line).length).toBe(0);
      // Flip swaps them; Either accepts both.
      expect(validLaps(rev, applyDirPref(line, 'flipped')).length).toBe(2);
      expect(validLaps(fwd, applyDirPref(line, 'flipped')).length).toBe(0);
      expect(validLaps(fwd, applyDirPref(line, 'either')).length).toBe(2);
      expect(validLaps(rev, applyDirPref(line, 'either')).length).toBe(2);
    } else {
      expect(line.dir).toBe(0);
      expect(validLaps(fwd, line).length).toBe(2);
      expect(validLaps(rev, line).length).toBe(2);
    }
    for (const lap of validLaps(fwd, line)) expect(lap.seconds).toBeCloseTo((2 * Math.PI * 300) / 40, 0);
  });

  it('direction preferences: apply, flip a non-directional line (stays 0), sanitize stored prefs', () => {
    const base: TimingLine = { a: { lat: 0, lon: 0 }, b: { lat: 0, lon: 1e-4 }, dir: 1 };
    expect(applyDirPref(base, 'stored').dir).toBe(1);
    expect(applyDirPref(base, 'flipped').dir).toBe(-1);
    expect(applyDirPref({ ...base, dir: -1 }, 'flipped').dir).toBe(1);
    expect(applyDirPref(base, 'either').dir).toBe(0);
    expect(applyDirPref({ ...base, dir: 0 }, 'flipped').dir).toBe(0);
    expect(normDirPrefs({ x: 'flipped', y: 'either', z: 'sideways', w: 3 })).toEqual({ x: 'flipped', y: 'either' });
    expect(normDirPrefs([1, 2])).toEqual({});
    expect(normDirPrefs(null)).toEqual({});
    expect(ALL_KEYS).toContain(SFL_DIR_KEY);
  });
});

/* ---------- 2. Spanish overlay for sourced facts ---------- */

describe('Spanish overlay for sourced facts', () => {
  it('every overlay key is a real spec record, and a note is only translated where the English has one', () => {
    const ids = new Map(specs.map((s) => [s.id, s]));
    for (const [id, o] of Object.entries(esOverlay.specs)) {
      expect(ids.has(id), id).toBe(true);
      if (o.note !== undefined) expect(ids.get(id)!.note, id).toBeTruthy();
      expect(o.label ?? o.note, id).toBeTruthy();
    }
    // Complete for labels and notes today; a new spec without a translation simply falls back to English.
    for (const s of specs) expect(esOverlay.specs[s.id]?.label, s.id).toBeTruthy();
  });

  it('falls back to English per field and marks translated text; values and sources are never touched', () => {
    expect(specText({ id: 'hp', label: 'Horsepower' }, 'es')).toEqual({ label: 'Potencia', note: undefined, translated: true });
    expect(specText({ id: 'hp', label: 'Horsepower' }, 'en')).toEqual({ label: 'Horsepower', note: undefined, translated: false });
    expect(specText({ id: 'no-such', label: 'X', note: 'N' }, 'es')).toEqual({ label: 'X', note: 'N', translated: false });
    expect(specText({ id: 'diff', label: 'Differential', note: 'English note' }, 'es')).toEqual({ label: 'Diferencial', note: 'English note', translated: true });
    const src = readFileSync('src/data/specs.ts', 'utf8');
    expect(src).toContain("label: 'Horsepower'"); // English data untouched
  });

  it('Specs page shows Spanish labels with a "traducido" marker, keeps values and sources, and English stays unmarked', () => {
    const esHtml = wrap(<Specs />, 'es');
    expect(esHtml).toContain('Potencia');
    expect(esHtml).toContain('traducido');
    expect(esHtml).toContain('760');
    expect(esHtml).toContain('Predator'); // value text stays English
    expect(esHtml).toContain('Ninguna fuente lo confirma.');
    const enHtml = wrap(<Specs />, 'en');
    expect(enHtml).toContain('Horsepower');
    expect(enHtml).not.toContain('translated');
  });
});

/* ---------- 4. diagnostics ---------- */

describe('field-test diagnostics', () => {
  beforeEach(() => { store.clear(); resetDiagCache(); vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('is off by default and records nothing until enabled', () => {
    diagLog({ k: 'gps', acc: 3, dtMs: 1000, mps: 20 });
    flushDiag();
    expect(loadDiag().entries).toEqual([]);
    expect(loadDiag().enabled).toBe(false);
  });

  it('records anonymized entries relative to the start, caps the log, summarizes and exports without coordinates or epoch time', () => {
    setDiagEnabled(true, 1_000_000);
    diagLog({ k: 'evt', src: 'timer', ev: 'start' }, 1_000_000);
    diagLog({ k: 'gps', acc: 3.5, dtMs: null, mps: 20 }, 1_000_500);
    diagLog({ k: 'gps', acc: 8, dtMs: 1000, mps: 21 }, 1_001_500);
    diagLog({ k: 'lap', n: 1, s: 92.345, valid: true, accM: 8, dir: 1 }, 1_002_000);
    diagLog({ k: 'obd', cmd: '010C', ok: true, err: null, bytes: 4, ms: 80 }, 1_002_100);
    diagLog({ k: 'obd', cmd: '0105', ok: false, err: 'noData', bytes: 0, ms: 120 }, 1_002_200);
    // Extra fields (e.g. a stray position) are dropped by normalization.
    diagLog({ k: 'gps', acc: 4, dtMs: 1000, mps: 1, lat: 36.1 } as never, 1_002_500);
    vi.advanceTimersByTime(1100);
    const s = loadDiag();
    expect(s.entries[1]).toEqual({ k: 'gps', t: 500, acc: 3.5, dtMs: null, mps: 20 });
    expect(JSON.stringify(s.entries)).not.toContain('36.1');
    const sum = summarizeDiag(s.entries);
    expect(sum).toMatchObject({ gps: 3, laps: 1, obd: 2, obdFail: 1, dtMax: 1000 });
    const out = JSON.parse(diagExport(s));
    expect(out.day).toBe('1970-01-01');
    expect(out).not.toHaveProperty('t0');
    expect(out.entries.length).toBe(7);
    for (let i = 0; i < MAX_DIAG + 10; i++) diagLog({ k: 'evt', src: 'gps', ev: 'x' }, 1_003_000 + i);
    flushDiag();
    expect(loadDiag().entries.length).toBe(MAX_DIAG);
    clearDiag();
    expect(loadDiag().entries).toEqual([]);
    expect(ALL_KEYS).toContain(DIAG_KEY);
  });

  it('OBD client reports every command to the observer, including transport failures', async () => {
    const seen: [string, string | null][] = [];
    const c = new ObdClient(fakeTransport({ values: () => ({ rpm: 1000 }) }));
    c.onCmd = (cmd, raw) => seen.push([cmd, raw]);
    await c.init(); await c.readSupported(); await c.read(['rpm']);
    expect(seen.map((x) => x[0])).toContain('010C');
    const bad = new ObdClient({ send: async () => { throw new Error('x'); }, close: async () => undefined });
    bad.onCmd = (cmd, raw) => seen.push([cmd, raw]);
    await expect(bad.cmd('ATZ')).rejects.toThrow();
    expect(seen[seen.length - 1]).toEqual(['ATZ', null]);
  });

  it('Diagnostics page renders the privacy statement, off state and export controls', () => {
    const html = wrap(<Diagnostics />);
    expect(html).toContain('Nothing leaves this device');
    expect(html).toContain('Recording is off.');
    expect(html).toContain('Export log (.json)');
    expect(wrap(<Diagnostics />, 'es')).toContain('Nada sale de este dispositivo');
  });
});

/* ---------- 5. round 13 bug hunt (regressions) ---------- */

describe('round 13 bug hunt', () => {
  it('OBD: "BUS INIT: ...OK" (ISO 9141 / KWP init) is not a bus error; "BUS INIT: ...ERROR" still is', () => {
    expect(readPidValue('rpm', 'SEARCHING...\rBUS INIT: ...OK\r410C1AF8\r\r>')).toBe(1726);
    expect(cleanResponse('BUS INIT: ...ERROR\r\r>')).toEqual({ error: 'busError' });
    expect(parseDtcs('03', 'BUS INIT: ...OK\r43 01 33 00 00 00 00\r>')?.map((d) => d.code)).toEqual(['P0133']);
  });

  it('BLE: a setup failure after connecting disconnects the adapter; a drop rejects the pending reply at once', async () => {
    vi.useFakeTimers();
    const mk = (opts: { failNotify?: boolean }) => {
      const listeners: Record<string, () => void> = {};
      let notify: ((e: Event) => void) | null = null;
      const gatt = {
        connected: false, disconnects: 0,
        async connect() { gatt.connected = true; return gatt; },
        disconnect() { gatt.connected = false; gatt.disconnects++; listeners.gattserverdisconnected?.(); },
        async getPrimaryService() {
          return { async getCharacteristic() {
            return { addEventListener: (_t: string, f: (e: Event) => void) => { notify = f; }, async startNotifications() { if (opts.failNotify) throw new Error('notify'); return this; }, async writeValue() { /* no reply */ } };
          } };
        },
      };
      const dev = { name: 'OBDII', gatt, addEventListener: (t: string, f: () => void) => { listeners[t] = f; } };
      const bt = { requestDevice: async () => dev } as unknown as Bluetooth;
      return { bt, gatt, drop: () => { gatt.connected = false; listeners.gattserverdisconnected?.(); }, notify: () => notify };
    };
    const a = mk({ failNotify: true });
    const lost = vi.fn();
    await expect(connectBle(lost, a.bt)).rejects.toThrow('notify');
    expect(a.gatt.connected).toBe(false);
    expect(a.gatt.disconnects).toBe(1);
    expect(lost).not.toHaveBeenCalled(); // a failed setup is not reported as a lost link

    const b = mk({});
    const lost2 = vi.fn();
    const tr = await connectBle(lost2, b.bt);
    const p = tr.send('ATZ');
    const settled = vi.fn();
    p.catch(settled);
    await vi.advanceTimersByTimeAsync(10);
    b.drop();
    await vi.advanceTimersByTimeAsync(10); // far less than the reply timeout
    expect(settled).toHaveBeenCalledWith(new Error('disconnected'));
    expect(lost2).toHaveBeenCalledTimes(1);
    await expect(tr.send('ATE0')).rejects.toThrow('disconnected');
    vi.useRealTimers();
  });

  it('tree: a red light within half a millisecond of green stays a red light after saving and reloading', () => {
    const s = schedule('pro', 1000);
    const r = classify(s, s.green - 0.3)!;
    expect(r.red).toBe(true);
    expect(r.rt).toBe(-0.001);
    const back = normResult(JSON.parse(JSON.stringify(r)));
    expect(back?.red).toBe(true);
    const ok = classify(s, s.green + 0.2)!;
    expect(ok).toMatchObject({ red: false, rt: 0 });
    expect(Object.is(ok.rt, -0)).toBe(false);
  });

  it('Ask: "1/4 mile" and "0 to 60" reach their intents (slashes are stripped by normalization)', () => {
    expect(ask('best 1/4 mile time')?.intent).toBe('quarter');
    expect(ask('1/4 milla')?.intent).toBe('quarter');
    expect(ask('quarter mile')?.intent).toBe('quarter');
    expect(ask('0 to 60')?.intent).toBe('zeroSixty');
    expect(ask('torque')?.intent).toBe('torque');
  });

  it('planner: repeated event ids are refused in backups and de-duplicated on load; repeated packing ids keep the first', () => {
    const ev = { id: 'e1', date: '2026-11-01', endDate: '', trackId: '', track: 'Thunderhill', group: '', org: '', notes: '', pack: [] };
    const b = makeBackup({ ...EMPTY_GARAGE }, [], [], [], [], DEFAULT_SETTINGS, undefined, undefined, { trackdays: [ev, { ...ev, track: 'Other' }] });
    const v = validateBackup(JSON.parse(JSON.stringify(b)));
    expect(v.ok).toBe(false);
    if (!v.ok) expect(v.errors).toContain('"trackdays" repeats an event id');
    expect(validateBackup(JSON.parse(JSON.stringify(makeBackup({ ...EMPTY_GARAGE }, [], [], [], [], DEFAULT_SETTINGS, undefined, undefined, { trackdays: [ev] })))).ok).toBe(true);
    store.set(TRACKDAYS_KEY, JSON.stringify([ev, { ...ev, track: 'Dup' }]));
    expect(loadTrackDays().map((d) => d.track)).toEqual(['Thunderhill']);
    const n = normTrackDay({ ...ev, pack: [{ id: 'p', label: 'Helmet', done: false }, { id: 'p', label: 'Gloves', done: true }] });
    expect(n?.pack).toEqual([{ id: 'p', label: 'Helmet', done: false }]);
  });

  it('every new UI string exists in English and Spanish', () => {
    for (const k of ['sfl.dirFlip', 'sfl.dirEither', 'diag.privacy', 'data.translated', 'nav.diagnostics', 'help.tool.diagnostics'] as const) {
      expect(en[k]).toBeTruthy();
      expect(es[k]).toBeTruthy();
    }
  });
});
