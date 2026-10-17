/**
 * Build & sticker: an original-MSRP "window sticker" assembled only from sourced records in packages.ts and
 * pricing.ts. Nothing is estimated: a line whose price is unknown for the chosen year is shown as unpriced and left
 * out of the total, which then reads "at least". Conflicting sourced values are kept next to the primary value.
 */
import { packages } from '../data/packages';
import { prices } from '../data/pricing';
import type { Confidence, ModelYear, OptionPackage, PriceRecord, SourcedValue } from '../data/types';
import { load, save } from './storage';

export const BUILD_YEARS: ModelYear[] = [2020, 2021, 2022];
export const BUILD_KEY = 'gt500.buildSheet.v1';
export type BaseKind = 'msrp' | 'destination' | 'gas-guzzler';
export const BASE_KINDS: BaseKind[] = ['msrp', 'destination', 'gas-guzzler'];

export interface StickerLine {
  id: string;
  kind: BaseKind | 'option';
  label: string;
  /** Primary sourced value used in the total; null when not sourced for this year. */
  value: number | null;
  source: string;
  confidence: Confidence;
  context?: string;
  note?: string;
  /** Other sourced values (conflicts), shown next to the primary value, never totalled. */
  conflicts: SourcedValue<number>[];
}
export interface BuildOption { pkg: OptionPackage; availability: 'listed' | 'unverified' }
export interface Sticker { year: ModelYear; lines: StickerLine[]; total: number; unpriced: number; atLeast: boolean }
export interface BuildState { year: ModelYear; options: string[] }

const YEAR_RE = /\b(2020|2021|2022)\b/g;
const yearsIn = (s: string | undefined): number[] => [...(s ?? '').matchAll(YEAR_RE)].map((m) => Number(m[1]));

/** Options to offer for a year: listed for that year, or year availability unknown (empty `years`). */
export function optionsFor(year: ModelYear, all: OptionPackage[] = packages): BuildOption[] {
  return all.filter((p) => p.years.length === 0 || p.years.includes(year))
    .map((p) => ({ pkg: p, availability: p.years.length === 0 ? 'unverified' : 'listed' }));
}

/**
 * The price that applies to a year. A price whose context names specific model years (e.g. "2020, USD") is only
 * used for those years; for other years the line is unpriced.
 */
export function optionPrice(p: OptionPackage, year: ModelYear): number | null {
  if (p.price.value === null) return null;
  const ys = yearsIn(p.price.context);
  return ys.length > 0 && !ys.includes(year) ? null : p.price.value;
}

/** Base-car MSRP records only (excludes e.g. the Heritage Edition base, a different configuration). */
const BASE_LABEL = /^Base MSRP/;

/** Base sticker lines for a year: the first record of each kind is primary, later ones of the same kind conflict. */
export function baseLines(year: ModelYear, all: PriceRecord[] = prices): StickerLine[] {
  return BASE_KINDS.map((kind) => {
    const recs = all.filter((r) => r.year === year && r.kind === kind && (kind !== 'msrp' || BASE_LABEL.test(r.label)));
    const [first, ...rest] = recs;
    if (!first) return { id: `base-${kind}`, kind, label: kind, value: null, source: '', confidence: 'unverified' as Confidence, conflicts: [] };
    const conflicts = rest.filter((r) => r.value !== first.value).map((r) => ({ value: r.value, source: r.source, confidence: r.confidence, context: r.label }));
    return { id: first.id, kind, label: first.label, value: first.value, source: first.source, confidence: first.confidence, note: first.note, conflicts };
  });
}

export function optionLine(p: OptionPackage, year: ModelYear): StickerLine {
  return {
    id: p.id, kind: 'option', label: p.name, value: optionPrice(p, year), source: p.price.source, confidence: p.price.confidence,
    context: p.price.context, note: p.price.note ?? p.note, conflicts: p.priceConflicts ?? [],
  };
}

/** Assemble the sticker. Selected ids not offered for the year are ignored. */
export function buildSticker(year: ModelYear, selected: string[], pkgs: OptionPackage[] = packages, recs: PriceRecord[] = prices): Sticker {
  const offered = optionsFor(year, pkgs);
  const lines = [...baseLines(year, recs), ...offered.filter((o) => selected.includes(o.pkg.id)).map((o) => optionLine(o.pkg, year))];
  const total = lines.reduce((s, l) => s + (l.value ?? 0), 0);
  const unpriced = lines.filter((l) => l.value === null).length;
  return { year, lines, total, unpriced, atLeast: unpriced > 0 };
}

const ID = /^[a-z0-9-]{1,40}$/;
export function normBuild(v: unknown): BuildState | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (!BUILD_YEARS.includes(o.year as ModelYear) || !Array.isArray(o.options)) return null;
  return { year: o.year as ModelYear, options: [...new Set(o.options.filter((x): x is string => typeof x === 'string' && ID.test(x)))].slice(0, 30) };
}
export const DEFAULT_BUILD: BuildState = { year: 2020, options: [] };
export const loadBuild = (): BuildState => normBuild(load<unknown>(BUILD_KEY, null)) ?? DEFAULT_BUILD;
export const saveBuild = (s: BuildState): boolean => save(BUILD_KEY, normBuild(s) ?? DEFAULT_BUILD);
