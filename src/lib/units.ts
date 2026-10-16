import { load, save } from './storage';
import { normLang, type Lang } from './i18n';

export type Units = 'imperial' | 'metric';
export type ThemePref = 'dark' | 'light' | 'system';
export interface Settings { units: Units; theme: ThemePref; lang: Lang }

export const SETTINGS_KEY = 'gt500.settings.v1';
const LEGACY_THEME_KEY = 'gt500.theme';
export const DEFAULT_SETTINGS: Settings = { units: 'imperial', theme: 'dark', lang: 'en' };

/** Read settings, migrating the pre-settings `gt500.theme` key once. */
export function loadSettings(): Settings {
  const s = load<Partial<Settings> | null>(SETTINGS_KEY, null);
  if (s) return normalizeSettings(s);
  const legacy = load<string | null>(LEGACY_THEME_KEY, null);
  return normalizeSettings({ theme: legacy === 'light' || legacy === 'dark' ? legacy : undefined });
}
export const saveSettings = (s: Settings) => save(SETTINGS_KEY, s);

export function normalizeSettings(v: unknown): Settings {
  const o = (v && typeof v === 'object' ? v : {}) as Record<string, unknown>;
  return {
    units: o.units === 'metric' ? 'metric' : 'imperial',
    theme: o.theme === 'light' || o.theme === 'system' ? o.theme : 'dark',
    lang: normLang(o.lang),
  };
}

export function resolveTheme(t: ThemePref, prefersDark: boolean): 'dark' | 'light' {
  return t === 'system' ? (prefersDark ? 'dark' : 'light') : t;
}

/** Quantity kinds. Values are always STORED in the imperial base unit and converted for display/entry. */
export type Kind = 'distance' | 'speed' | 'weight' | 'length' | 'volume' | 'temp' | 'pressure' | 'altitude' | 'torque' | 'economy' | 'shortLength';

const MI_KM = 1.609344;
const LB_KG = 0.45359237;
const GAL_L = 3.785411784;
const FT_M = 0.3048;
const INHG_HPA = 33.8638866667;
const LBFT_NM = 1.3558179483;

export const UNIT_LABEL: Record<Kind, Record<Units, string>> = {
  distance: { imperial: 'mi', metric: 'km' },
  speed: { imperial: 'mph', metric: 'km/h' },
  weight: { imperial: 'lb', metric: 'kg' },
  length: { imperial: 'in', metric: 'mm' },
  shortLength: { imperial: 'ft', metric: 'm' },
  volume: { imperial: 'gal', metric: 'L' },
  temp: { imperial: '°F', metric: '°C' },
  pressure: { imperial: 'inHg', metric: 'hPa' },
  altitude: { imperial: 'ft', metric: 'm' },
  torque: { imperial: 'lb-ft', metric: 'N·m' },
  economy: { imperial: 'mpg', metric: 'L/100 km' },
};

/** Imperial base → display unit. */
export function toDisplay(kind: Kind, v: number, u: Units): number {
  if (u === 'imperial') return v;
  switch (kind) {
    case 'distance': case 'speed': return v * MI_KM;
    case 'weight': return v * LB_KG;
    case 'length': return v * 25.4;
    case 'shortLength': case 'altitude': return v * FT_M;
    case 'volume': return v * GAL_L;
    case 'temp': return (v - 32) * 5 / 9;
    case 'pressure': return v * INHG_HPA;
    case 'torque': return v * LBFT_NM;
    case 'economy': return v > 0 ? 235.214583 / v : NaN;
  }
}

/** Display unit → imperial base. */
export function fromDisplay(kind: Kind, v: number, u: Units): number {
  if (u === 'imperial') return v;
  switch (kind) {
    case 'distance': case 'speed': return v / MI_KM;
    case 'weight': return v / LB_KG;
    case 'length': return v / 25.4;
    case 'shortLength': case 'altitude': return v / FT_M;
    case 'volume': return v / GAL_L;
    case 'temp': return v * 9 / 5 + 32;
    case 'pressure': return v / INHG_HPA;
    case 'torque': return v / LBFT_NM;
    case 'economy': return v > 0 ? 235.214583 / v : NaN;
  }
}

export const unitLabel = (kind: Kind, u: Units) => UNIT_LABEL[kind][u];

/** Text shown in a unit input for an imperial base value ('' when unknown or not convertible, e.g. 0 mpg in L/100 km). */
export function formatUnitInput(kind: Kind | null, v: number | null, u: Units, digits: number): string {
  if (v === null || !Number.isFinite(v)) return '';
  const d = kind ? toDisplay(kind, v, u) : v;
  return Number.isFinite(d) ? String(Number(d.toFixed(digits))) : '';
}

/** Parse typed text in display units back to the imperial base; null for blank, non-numeric or non-convertible input. */
export function parseUnitInput(kind: Kind | null, text: string, u: Units): number | null {
  const s = text.trim().replace(/,/g, '');
  if (s === '') return null;
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  const b = kind ? fromDisplay(kind, n, u) : n;
  return Number.isFinite(b) ? b : null;
}

/** Format an imperial base value in the chosen units, e.g. fmtQty('speed', 133, 'metric') → "214 km/h". */
export function fmtQty(kind: Kind, v: number | null | undefined, u: Units, digits = 0): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—';
  const d = toDisplay(kind, v, u);
  return `${d.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })} ${unitLabel(kind, u)}`;
}

/** Spec unit strings (from data/specs.ts) that are converted in metric mode. */
const SPEC_UNITS: { match: RegExp; kind: Kind; digits: number; label?: string }[] = [
  { match: /^in$/, kind: 'length', digits: 0 },
  { match: /^lb$/, kind: 'weight', digits: 0 },
  { match: /^mph/, kind: 'speed', digits: 0 },
  { match: /^gal/, kind: 'volume', digits: 0 },
  { match: /^lb-ft/, kind: 'torque', digits: 0 },
  { match: /^mpg$/, kind: 'economy', digits: 1 },
];

/**
 * Convert every number in a spec value string. Imperial returns the input unchanged.
 * Returns the converted value text and unit text (the rest of the unit, e.g. "@ 5,000 rpm", is kept).
 */
export function convertSpec(value: string | number, unit: string | undefined, u: Units): { value: string | number; unit: string | undefined } {
  if (u === 'imperial' || !unit) return { value, unit };
  const rule = SPEC_UNITS.find((r) => r.match.test(unit));
  if (!rule) return { value, unit };
  const conv = (n: number) => toDisplay(rule.kind, n, u).toLocaleString('en-US', { maximumFractionDigits: rule.digits });
  const out = typeof value === 'number' ? conv(value) : value.replace(/\d[\d,]*(\.\d+)?/g, (m) => conv(Number(m.replace(/,/g, ''))));
  const rest = unit.replace(rule.match, '').trim();
  return { value: out, unit: [unitLabel(rule.kind, u), rest].filter(Boolean).join(' ') };
}
