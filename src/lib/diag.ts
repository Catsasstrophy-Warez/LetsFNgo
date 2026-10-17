/**
 * Field-test diagnostics: an opt-in, local-only debug log of GPS fix quality, lap-timer crossings and OBD-II
 * request/response timing, so a real session on a phone at a track can be reviewed afterwards.
 *
 * Privacy: recording is OFF by default and only starts from Settings → Diagnostics. Entries are anonymized before they
 * are stored — no coordinates, no VIN, no device or adapter names, no wall-clock times (only ms since the recording
 * started and the calendar day it started). Nothing is sent anywhere: the log lives in localStorage and leaves the
 * device only when the user taps "Export" and saves the file themselves.
 */
import { load, save } from './storage';

export const DIAG_KEY = 'gt500.diag.v1';
/** Newest entries kept (older ones are dropped first). */
export const MAX_DIAG = 3000;

export type DiagEntry =
  /** One GPS fix: horizontal accuracy (m), gap since the previous fix (ms, null for the first), speed (m/s or null). */
  | { k: 'gps'; t: number; acc: number; dtMs: number | null; mps: number | null }
  /** A start/finish crossing that completed a lap: lap number, lap seconds, valid flag, worst accuracy, line direction setting. */
  | { k: 'lap'; t: number; n: number; s: number; valid: boolean; accM: number; dir: 1 | -1 | 0 }
  /** One OBD command: the (read-only) command, reply status, payload byte count, round-trip ms. */
  | { k: 'obd'; t: number; cmd: string; ok: boolean; err: string | null; bytes: number; ms: number }
  /** A free-form event (start / stop / connect / disconnect). Codes only, never user text. */
  | { k: 'evt'; t: number; src: 'gps' | 'obd' | 'timer'; ev: string };

export interface DiagStore { enabled: boolean; /** YYYY-MM-DD the current log started. */ day: string; /** Epoch ms the log started (kept local, never exported). */ t0: number; entries: DiagEntry[] }
const EMPTY: DiagStore = { enabled: false, day: '', t0: 0, entries: [] };

const num = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
function normEntry(v: unknown): DiagEntry | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as Record<string, unknown>;
  if (!num(o.t)) return null;
  const t = o.t as number;
  switch (o.k) {
    case 'gps': return num(o.acc) ? { k: 'gps', t, acc: o.acc as number, dtMs: num(o.dtMs) ? (o.dtMs as number) : null, mps: num(o.mps) ? (o.mps as number) : null } : null;
    case 'lap': return num(o.n) && num(o.s) && num(o.accM) ? { k: 'lap', t, n: o.n as number, s: o.s as number, valid: o.valid === true, accM: o.accM as number, dir: o.dir === 1 || o.dir === -1 ? o.dir : 0 } : null;
    case 'obd': return typeof o.cmd === 'string' && num(o.bytes) && num(o.ms) ? { k: 'obd', t, cmd: o.cmd.slice(0, 8), ok: o.ok === true, err: typeof o.err === 'string' ? o.err.slice(0, 20) : null, bytes: o.bytes as number, ms: o.ms as number } : null;
    case 'evt': return (o.src === 'gps' || o.src === 'obd' || o.src === 'timer') && typeof o.ev === 'string' ? { k: 'evt', t, src: o.src, ev: o.ev.slice(0, 24) } : null;
    default: return null;
  }
}

export function loadDiag(): DiagStore {
  const v = load<unknown>(DIAG_KEY, null);
  if (!v || typeof v !== 'object') return { ...EMPTY, entries: [] };
  const o = v as Record<string, unknown>;
  return {
    enabled: o.enabled === true, day: typeof o.day === 'string' ? o.day.slice(0, 10) : '', t0: num(o.t0) ? (o.t0 as number) : 0,
    entries: Array.isArray(o.entries) ? o.entries.map(normEntry).filter((x): x is DiagEntry => !!x).slice(-MAX_DIAG) : [],
  };
}
const saveDiag = (s: DiagStore) => save(DIAG_KEY, { ...s, entries: s.entries.slice(-MAX_DIAG) });

let cache: DiagStore | null = null;
const store = () => (cache ??= loadDiag());
/** Drop the in-memory copy (tests, or after another tab changed it). */
export const resetDiagCache = () => { cache = null; };

export const diagEnabled = () => store().enabled;

/** Turn recording on or off. Turning it on starts a fresh clock if the log is empty. */
export function setDiagEnabled(on: boolean, now = Date.now()): DiagStore {
  const s = store();
  const day = new Date(now).toISOString().slice(0, 10);
  cache = { ...s, enabled: on, ...(on && !s.entries.length ? { t0: now, day } : {}) };
  saveDiag(cache);
  return cache;
}

export function clearDiag(now = Date.now()): DiagStore {
  cache = { ...store(), entries: [], t0: now, day: new Date(now).toISOString().slice(0, 10) };
  saveDiag(cache);
  return cache;
}

type NoT<E> = E extends DiagEntry ? Omit<E, 't'> : never;
/** Append one entry when recording is on (a no-op otherwise). Writes are throttled to one per second. */
export function diagLog(e: NoT<DiagEntry>, now = Date.now()): void {
  const s = store();
  if (!s.enabled) return;
  if (!s.t0) { s.t0 = now; s.day = new Date(now).toISOString().slice(0, 10); }
  const entry = normEntry({ ...e, t: Math.max(0, Math.round(now - s.t0)) });
  if (!entry) return;
  s.entries.push(entry);
  if (s.entries.length > MAX_DIAG) s.entries.splice(0, s.entries.length - MAX_DIAG);
  scheduleFlush();
}
let timer: ReturnType<typeof setTimeout> | null = null;
function scheduleFlush() {
  if (timer) return;
  timer = setTimeout(() => { timer = null; if (cache) saveDiag(cache); }, 1000);
}
/** Write pending entries now (page hide, export). */
export function flushDiag(): void { if (timer) { clearTimeout(timer); timer = null; } if (cache) saveDiag(cache); }

const pct = (xs: number[], p: number) => { if (!xs.length) return null; const s = xs.slice().sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };

/** Summary for the Diagnostics page. */
export function summarizeDiag(entries: DiagEntry[]) {
  const gps = entries.filter((e): e is Extract<DiagEntry, { k: 'gps' }> => e.k === 'gps');
  const obd = entries.filter((e): e is Extract<DiagEntry, { k: 'obd' }> => e.k === 'obd');
  const laps = entries.filter((e) => e.k === 'lap').length;
  const acc = gps.map((g) => g.acc), dts = gps.map((g) => g.dtMs).filter((x): x is number => x !== null);
  return {
    gps: gps.length, accP50: pct(acc, 50), accP95: pct(acc, 95), dtP50: pct(dts, 50), dtMax: dts.length ? Math.max(...dts) : null,
    laps, obd: obd.length, obdFail: obd.filter((o) => !o.ok).length, obdP50: pct(obd.map((o) => o.ms), 50),
  };
}

/** Export JSON: the anonymized entries plus a summary. The epoch start time is deliberately left out. */
export function diagExport(s: DiagStore, appVersion = '') {
  return JSON.stringify({ app: 'gt500-companion-diagnostics', version: 1, appVersion, day: s.day, summary: summarizeDiag(s.entries), entries: s.entries }, null, 1);
}
