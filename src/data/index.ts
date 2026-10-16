import { specs } from './specs';
import { modelYears } from './modelYears';
import { colors } from './colors';
import { packages } from './packages';
import { prices, marketSales } from './pricing';
import { production } from './production';
import { performance, performanceWarning } from './performance';
import { recalls } from './recalls';
import { maintenance } from './maintenance';
import { vinPositions } from './vin';
import { modStages, warrantyNote } from './mods';
import { competitors } from './competitors';
import { communities } from './communities';
import { media, licensingNotes, photos, audio } from './media';
import type { Sourced } from './types';

/** Every collection of sourced records, keyed by name. Used by search, Sources page and tests. */
export const collections: Record<string, Sourced[]> = {
  specs, modelYears, colors, packages, prices, marketSales, production, performance,
  recalls, maintenance, vinPositions, modStages, competitors, communities, media, photos, audio,
  notes: [performanceWarning, warrantyNote, ...licensingNotes],
};

/** Walk any value and collect every nested object that looks like a sourced record. */
export function collectSourced(value: unknown, out: Sourced[] = []): Sourced[] {
  if (Array.isArray(value)) value.forEach((v) => collectSourced(v, out));
  else if (value && typeof value === 'object') {
    const o = value as Record<string, unknown>;
    if ('source' in o || 'confidence' in o) out.push(o as unknown as Sourced);
    Object.values(o).forEach((v) => collectSourced(v, out));
  }
  return out;
}

export function allSourceUrls(): string[] {
  const urls = new Set<string>();
  collectSourced(Object.values(collections)).forEach((s) => urls.add(s.source));
  return [...urls].sort();
}

export const REPORT_PATH = 'reports/Shelby GT500 2020 to 2022.md';
