/**
 * Read-only OBD-II over an ELM327-style adapter. Pure parsing (SAE J1979 Mode 01 / 03 / 07 responses) plus a small
 * client that refuses every command that is not on a read-only allow-list, so Mode 04 (clear codes) or any write
 * command can never be sent — not by the UI, not by a bug.
 *
 * Formulas are the standard SAE J1979 ones (https://en.wikipedia.org/wiki/OBD-II_PIDs). GT500 support for each PID is
 * unverified, so the app reads the supported-PID bitmaps (01 00 / 20 / 40 / 60) at connect and only shows gauges the
 * car reports. Ford Mode 22 extended PIDs are not supported.
 */

export const OBD_SOURCE = 'https://en.wikipedia.org/wiki/OBD-II_PIDs';
/** HP Tuners forum thread: the 2017 GT350 5.2L has no oil-temperature PID (reported, not GT500-specific). */
export const OIL_TEMP_NOTE_SOURCE = 'https://forum.hptuners.com/showthread.php?p=864663';

/** ELM327 init: reset, echo off, linefeeds off, spaces off, headers off, automatic protocol. */
export const ELM_INIT = ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0'] as const;
/** AT commands the client may send (adapter configuration only — none of them talk to the car). */
const AT_ALLOWED = new Set(['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0', 'ATDPN', 'ATRV', 'ATI', 'ATWS']);

export class ReadOnlyError extends Error {
  constructor(public cmd: string) { super(`Refused non-read-only command: ${cmd}`); }
}

/**
 * Throws ReadOnlyError unless `cmd` is an allowed AT command, a Mode 01 PID request (`01` + 2 hex digits) or a bare
 * Mode 03 / 07 request. Everything else — Mode 04 (clear DTCs), 08 (control), 2E/2F/31/3B (writes, routines) — is refused.
 */
export function assertReadOnly(raw: string): string {
  const cmd = raw.replace(/\s+/g, '').toUpperCase();
  if (AT_ALLOWED.has(cmd)) return cmd;
  if (/^01[0-9A-F]{2}$/.test(cmd) || cmd === '03' || cmd === '07') return cmd;
  throw new ReadOnlyError(cmd);
}

export type PidKey = 'rpm' | 'speed' | 'coolant' | 'iat' | 'map' | 'throttle' | 'oil' | 'baro';
export interface PidDef { pid: string; key: PidKey; bytes: number; /** Decoded to SI-ish base: rpm, km/h, °C, kPa, %. */ decode: (d: number[]) => number }
export const PIDS: PidDef[] = [
  { pid: '0C', key: 'rpm', bytes: 2, decode: ([a, b]) => (256 * a + b) / 4 },
  { pid: '0D', key: 'speed', bytes: 1, decode: ([a]) => a },
  { pid: '05', key: 'coolant', bytes: 1, decode: ([a]) => a - 40 },
  { pid: '0F', key: 'iat', bytes: 1, decode: ([a]) => a - 40 },
  { pid: '0B', key: 'map', bytes: 1, decode: ([a]) => a },
  { pid: '11', key: 'throttle', bytes: 1, decode: ([a]) => (a * 100) / 255 },
  { pid: '5C', key: 'oil', bytes: 1, decode: ([a]) => a - 40 },
  { pid: '33', key: 'baro', bytes: 1, decode: ([a]) => a },
];
export const pidDef = (key: PidKey) => PIDS.find((p) => p.key === key)!;
/** PID 0B reads at most 255 kPa (one byte), so boost above ~23 psi gauge cannot be shown. */
export const MAP_MAX_KPA = 255;

export type ElmError = 'noData' | 'unableToConnect' | 'unknownCommand' | 'busError' | 'stopped' | 'empty';
const ERRORS: [RegExp, ElmError][] = [
  [/NO ?DATA/, 'noData'], [/UNABLE ?TO ?CONNECT/, 'unableToConnect'], [/BUS ?(INIT|ERROR|BUSY)|CAN ?ERROR|FB ?ERROR|DATA ?ERROR/, 'busError'],
  [/STOPPED/, 'stopped'], [/^\?$/, 'unknownCommand'],
];

/** Clean an adapter reply: drop the `>` prompt, echo, `SEARCHING...`, blank lines; uppercase. Returns lines or an error. */
export function cleanResponse(raw: string, echo?: string): { lines: string[] } | { error: ElmError } {
  // "BUS INIT: ...OK" is the ISO 9141 / KWP init succeeding (not an error); "BUS INIT: ...ERROR" still is one.
  const lines = raw.replace(/>/g, '').split(/[\r\n]+/).map((l) => l.trim().toUpperCase())
    .filter((l) => l && !/^SEARCHING/.test(l) && !/^BUS ?INIT:?[ .]*OK$/.test(l) && l !== echo?.toUpperCase());
  for (const l of lines) for (const [re, e] of ERRORS) if (re.test(l.replace(/\s+/g, ' '))) return { error: e };
  if (!lines.length) return { error: 'empty' };
  return { lines };
}

/** Hex string → bytes (spaces ignored). Null when it is not whole hex bytes. */
export function hexBytes(s: string): number[] | null {
  const h = s.replace(/\s+/g, '');
  if (!h || h.length % 2 || !/^[0-9A-F]+$/i.test(h)) return null;
  return h.match(/../g)!.map((x) => parseInt(x, 16));
}

/**
 * Data bytes of a Mode 01 reply for `pid`: the first line (one per ECU) that starts with 41 + pid. Lines may carry
 * spaces. Returns null for errors or when no ECU answered that PID.
 */
export function parseMode01(pid: string, raw: string, bytes = 1): number[] | null {
  const c = cleanResponse(raw);
  if ('error' in c) return null;
  const want = 0x41, p = parseInt(pid, 16);
  for (const l of c.lines) {
    const b = hexBytes(l.replace(/^[0-9A-F]:/, ''));
    if (b && b.length >= 2 + bytes && b[0] === want && b[1] === p) return b.slice(2, 2 + bytes);
  }
  return null;
}

/** Decoded value of one PID reply (base units: rpm, km/h, °C, kPa, %), or null. */
export function readPidValue(key: PidKey, raw: string): number | null {
  const d = pidDef(key);
  const b = parseMode01(d.pid, raw, d.bytes);
  return b ? d.decode(b) : null;
}

/** PIDs flagged in a 4-byte support bitmap returned for `base` (00, 20, 40, 60). Bit 7 of byte 0 is base + 1. */
export function parseSupported(base: number, data: number[]): number[] {
  const out: number[] = [];
  data.slice(0, 4).forEach((byte, i) => { for (let bit = 0; bit < 8; bit++) if (byte & (0x80 >> bit)) out.push(base + i * 8 + bit + 1); });
  return out;
}
export const SUPPORT_BASES = [0x00, 0x20, 0x40, 0x60] as const;
export const pidHex = (n: number) => n.toString(16).toUpperCase().padStart(2, '0');

/* ---------- DTCs (Mode 03 stored, Mode 07 pending) ---------- */

export type DtcSystem = 'P' | 'C' | 'B' | 'U';
export interface Dtc { code: string; system: DtcSystem; /** true for SAE-generic codes (second char 0, or P2 / P34–P39), false for manufacturer-specific. */ generic: boolean }

/** Decode two DTC bytes (SAE J2012 format). Null for the 0000 padding. */
export function decodeDtc(a: number, b: number): Dtc | null {
  if (!a && !b) return null;
  const system = (['P', 'C', 'B', 'U'] as const)[a >> 6];
  const code = `${system}${(a >> 4) & 3}${(a & 0xf).toString(16).toUpperCase()}${pidHex(b)}`;
  const d1 = code[1], d2 = code[2];
  const generic = d1 === '0' || (system === 'P' && (d1 === '2' || (d1 === '3' && d2 >= '4' && d2 <= '9')));
  return { code, system, generic };
}

/**
 * Parse a Mode 03 / 07 reply. Handles legacy (43 + 3 pairs per line, zero padded), CAN single-frame
 * (43 + count byte + pairs) and CAN multi-frame with headers off (`00A` length line, then `0:` `1:` … frames).
 */
export function parseDtcs(mode: '03' | '07', raw: string): Dtc[] | null {
  const c = cleanResponse(raw);
  if ('error' in c) return c.error === 'noData' ? [] : null;
  const resp = mode === '03' ? 0x43 : 0x47;
  const out: Dtc[] = [];
  const seen = new Set<string>();
  const take = (bytes: number[]) => {
    for (let i = 0; i + 1 < bytes.length; i += 2) {
      const d = decodeDtc(bytes[i], bytes[i + 1]);
      if (d && !seen.has(d.code)) { seen.add(d.code); out.push(d); }
    }
  };
  const multi = c.lines.some((l) => /^[0-9A-F]:/.test(l));
  if (multi) {
    // Frames of one ECU, in order; the first frame starts with the mode byte and the count byte.
    const data = c.lines.filter((l) => /^[0-9A-F]:/.test(l)).flatMap((l) => hexBytes(l.slice(2)) ?? []);
    const len = c.lines.find((l) => /^[0-9A-F]{3}$/.test(l));
    const bytes = len ? data.slice(0, parseInt(len, 16)) : data;
    if (bytes[0] !== resp) return null;
    take(bytes.slice(2));
    return out;
  }
  let any = false;
  for (const l of c.lines) {
    const b = hexBytes(l);
    if (!b || b[0] !== resp) continue;
    any = true;
    const rest = b.slice(1);
    take(rest.length % 2 ? rest.slice(1) : rest); // odd length: CAN count byte first
  }
  return any ? out : null;
}

/** Generic lookup link for a code (descriptions are not included in the app). */
export const dtcLookupUrl = (code: string) => `https://www.obd-codes.com/${code.toLowerCase()}`;

/* ---------- transport + read-only client ---------- */

export interface ObdTransport {
  /** Send one command line; resolve with the raw reply up to the `>` prompt. */
  send(cmd: string): Promise<string>;
  close(): Promise<void>;
  /** True for simulated data (demo mode, tests). */
  simulated?: boolean;
}

export interface Reading { rpm: number | null; speed: number | null; coolant: number | null; iat: number | null; map: number | null; throttle: number | null; oil: number | null; baro: number | null }
export const EMPTY_READING: Reading = { rpm: null, speed: null, coolant: null, iat: null, map: null, throttle: null, oil: null, baro: null };

/** Wraps a transport; every command goes through `assertReadOnly` first. */
export class ObdClient {
  supported = new Set<number>();
  sent: string[] = [];
  /** Optional observer of every command (diagnostics): command, raw reply or null on failure, round-trip ms. */
  onCmd?: (cmd: string, raw: string | null, ms: number) => void;
  constructor(private t: ObdTransport) {}
  get simulated() { return !!this.t.simulated; }
  async cmd(c: string): Promise<string> {
    const safe = assertReadOnly(c);
    this.sent.push(safe);
    if (!this.onCmd) return this.t.send(safe);
    const t0 = Date.now();
    try { const r = await this.t.send(safe); this.onCmd(safe, r, Date.now() - t0); return r; } catch (e) { this.onCmd(safe, null, Date.now() - t0); throw e; }
  }
  async init(): Promise<void> {
    for (const c of ELM_INIT) await this.cmd(c);
  }
  /** Read the support bitmaps 00 → 20 → 40 → 60, following the "next range supported" bit. */
  async readSupported(): Promise<Set<number>> {
    const s = new Set<number>();
    for (const base of SUPPORT_BASES) {
      const b = parseMode01(pidHex(base), await this.cmd(`01${pidHex(base)}`), 4);
      if (!b) break;
      parseSupported(base, b).forEach((p) => s.add(p));
      if (!s.has(base + 0x20)) break;
    }
    this.supported = s;
    return s;
  }
  isSupported(key: PidKey) { return this.supported.has(parseInt(pidDef(key).pid, 16)); }
  async read(keys: PidKey[]): Promise<Reading> {
    const r: Reading = { ...EMPTY_READING };
    for (const k of keys) if (this.isSupported(k)) r[k] = readPidValue(k, await this.cmd(`01${pidDef(k).pid}`));
    return r;
  }
  async readDtcs(): Promise<{ stored: Dtc[] | null; pending: Dtc[] | null }> {
    return { stored: parseDtcs('03', await this.cmd('03')), pending: parseDtcs('07', await this.cmd('07')) };
  }
  close() { return this.t.close(); }
}

/** Boost (kPa gauge) = MAP − barometric pressure; null unless both are known. Negative = vacuum. */
export const boostKpa = (r: Pick<Reading, 'map' | 'baro'>) => (r.map !== null && r.baro !== null ? r.map - r.baro : null);

/* ---------- fake / simulated transport ---------- */

export interface FakeOpts {
  /** Supported PIDs (decimal). Default: 0C 0D 05 0F 0B 11 33 (no oil temp). */
  supported?: number[];
  values?: (t: number) => Partial<Record<PidKey, number>>;
  stored?: string[]; pending?: string[];
  simulated?: boolean;
  now?: () => number;
}
const encodeDtc = (code: string) => {
  const sys = 'PCBU'.indexOf(code[0]);
  const a = (sys << 6) | (Number(code[1]) << 4) | parseInt(code[2], 16);
  return pidHex(a) + code.slice(3, 5).toUpperCase();
};
/** Bitmap bytes for `base` from a list of supported PIDs. */
export function encodeSupported(base: number, list: number[]): string {
  const b = [0, 0, 0, 0];
  for (const p of list) { const k = p - base - 1; if (k >= 0 && k < 32) b[k >> 3] |= 0x80 >> (k & 7); }
  return b.map(pidHex).join('');
}
const encodeValue = (k: PidKey, v: number) => {
  switch (k) {
    case 'rpm': { const n = Math.max(0, Math.min(65535, Math.round(v * 4))); return pidHex(n >> 8) + pidHex(n & 255); }
    case 'throttle': return pidHex(Math.max(0, Math.min(255, Math.round((v * 255) / 100))));
    case 'coolant': case 'iat': case 'oil': return pidHex(Math.max(0, Math.min(255, Math.round(v + 40))));
    default: return pidHex(Math.max(0, Math.min(255, Math.round(v))));
  }
};

/** An ELM327 stand-in for tests and demo mode. Records every command it receives. */
export function fakeTransport(o: FakeOpts = {}): ObdTransport & { log: string[] } {
  const now = o.now ?? (() => Date.now());
  const t0 = now();
  const supported = o.supported ?? [0x0c, 0x0d, 0x05, 0x0f, 0x0b, 0x11, 0x33];
  const all = [...supported, ...supported.some((p) => p > 0x20) ? [0x20] : [], ...supported.some((p) => p > 0x40) ? [0x40] : [], ...supported.some((p) => p > 0x60) ? [0x60] : []];
  const log: string[] = [];
  return {
    log, simulated: o.simulated ?? true,
    async send(cmd) {
      log.push(cmd);
      if (cmd.startsWith('AT')) return cmd === 'ATZ' ? 'ELM327 v1.5\r\r>' : 'OK\r\r>';
      if (cmd === '03' || cmd === '07') {
        const list = (cmd === '03' ? o.stored : o.pending) ?? [];
        if (!list.length) return 'NO DATA\r\r>';
        return `${cmd === '03' ? '43' : '47'}${pidHex(list.length)}${list.map(encodeDtc).join('')}\r\r>`;
      }
      const p = parseInt(cmd.slice(2), 16);
      if ([0, 0x20, 0x40, 0x60].includes(p)) return all.some((x) => x > p && x <= p + 0x20) || p === 0 ? `41${cmd.slice(2)}${encodeSupported(p, all)}\r\r>` : 'NO DATA\r\r>';
      const def = PIDS.find((d) => parseInt(d.pid, 16) === p);
      if (!def || !supported.includes(p)) return 'NO DATA\r\r>';
      const v = o.values?.((now() - t0) / 1000)[def.key];
      return v === undefined ? 'NO DATA\r\r>' : `41${def.pid}${encodeValue(def.key, v)}\r\r>`;
    },
    async close() { /* nothing */ },
  };
}

/** Simulated drive for demo mode: a repeating 30 s cycle of idle, pull through the gears and cruise. */
export function demoValues(t: number): Partial<Record<PidKey, number>> {
  const c = t % 30;
  const pull = c > 6 && c < 16 ? (c - 6) / 10 : 0;
  const gearPhase = (pull * 4) % 1;
  const rpm = pull ? 3000 + gearPhase * 4200 : c < 6 ? 800 + 40 * Math.sin(t * 3) : 2200 + 150 * Math.sin(t);
  const speed = pull ? 30 + pull * 150 : c < 6 ? 0 : Math.max(0, 180 - (c - 16) * 8);
  return {
    rpm, speed, coolant: 88 + 4 * Math.sin(t / 20), iat: 32 + 6 * pull, baro: 101,
    map: pull ? 101 + 80 * Math.min(1, gearPhase * 2) : c < 6 ? 35 : 60, throttle: pull ? 98 : c < 6 ? 0 : 18,
  };
}
export const demoTransport = (now?: () => number) => fakeTransport({ values: demoValues, simulated: true, now, stored: [], pending: [] });

/* ---------- session log ---------- */

export interface ObdSample { /** ms since the session start. */ t: number; r: Reading }
export const MAX_SAMPLES = 20_000;

/** Session summary in display-independent base units. */
export function summarize(samples: ObdSample[]) {
  const max = (k: PidKey) => { const v = samples.map((s) => s.r[k]).filter((x): x is number => x !== null); return v.length ? v.reduce((a, b) => Math.max(a, b), -Infinity) : null; };
  const boosts = samples.map((s) => boostKpa(s.r)).filter((x): x is number => x !== null);
  return {
    n: samples.length, seconds: samples.length ? Math.round((samples[samples.length - 1].t - samples[0].t) / 100) / 10 : 0,
    rpm: max('rpm'), speed: max('speed'), coolant: max('coolant'), iat: max('iat'), oil: max('oil'),
    boost: boosts.length ? boosts.reduce((a, b) => Math.max(a, b), -Infinity) : null,
  };
}

/** CSV of a session (metric base units, RFC 4180, CRLF). Numbers only, so no formula-injection risk. */
export function samplesCsv(samples: ObdSample[], simulated: boolean): string {
  const head = ['t_s', 'rpm', 'speed_kmh', 'coolant_c', 'iat_c', 'map_kpa', 'baro_kpa', 'boost_kpa', 'throttle_pct', 'oil_c', 'simulated'];
  const f = (v: number | null, d = 1) => (v === null ? '' : String(Math.round(v * 10 ** d) / 10 ** d));
  const rows = samples.map((s) => [f(s.t / 1000, 3), f(s.r.rpm, 0), f(s.r.speed, 0), f(s.r.coolant, 0), f(s.r.iat, 0), f(s.r.map, 0), f(s.r.baro, 0), f(boostKpa(s.r), 0), f(s.r.throttle), f(s.r.oil, 0), simulated ? 'yes' : 'no'].join(','));
  return [head.join(','), ...rows].join('\r\n') + '\r\n';
}
