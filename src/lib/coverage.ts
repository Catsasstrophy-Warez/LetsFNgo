/**
 * Data coverage, computed from src/data at runtime: confidence counts per section, every null (gap) field and
 * what the notes say is needed, every conflict, and a source-domain breakdown. Nothing here is hand-maintained.
 */
import type { Confidence, Sourced } from '../data/types';

export const CONFIDENCES: Confidence[] = ['confirmed', 'reported', 'unverified'];
type Counts = Record<Confidence, number>;
const zero = (): Counts => ({ confirmed: 0, reported: 0, unverified: 0 });
type Obj = Record<string, unknown>;

/** Where each collection shows in the app (record → route). */
export function routeFor(collection: string, r: Obj): string {
  if (collection === 'guides' && typeof r.id === 'string') return `/guides/${r.id}`;
  if (collection === 'fpCatalog') return '/parts?tab=fp';
  return ROUTES[collection] ?? '/sources';
}
const ROUTES: Record<string, string> = {
  specs: '/specs', modelYears: '/years', colors: '/colors', packages: '/packages', prices: '/packages', marketSales: '/packages',
  production: '/years', performance: '/performance', recalls: '/ownership', maintenance: '/ownership', vinPositions: '/vin',
  modStages: '/mods', competitors: '/compare', communities: '/community', media: '/media', photos: '/media', audio: '/media',
  dynoBaselines: '/dyno', partNumbers: '/parts', auctionResults: '/market', marketStats: '/market', editions: '/editions',
  events: '/history', milestones: '/history', notes: '/sources',
};

export function labelOf(r: Obj): string {
  for (const k of ['label', 'name', 'title', 'item', 'stage', 'positions', 'id', 'text']) if (typeof r[k] === 'string' && r[k]) return (r[k] as string).slice(0, 90);
  return '—';
}

export function hostOf(url: string): string {
  try { return new URL(url).hostname.replace(/^www\d?\.|^www-backend\./, ''); } catch { return url; }
}

function eachSourced(v: unknown, f: (o: Obj) => void) {
  if (Array.isArray(v)) v.forEach((x) => eachSourced(x, f));
  else if (v && typeof v === 'object') {
    const o = v as Obj;
    if ('source' in o && 'confidence' in o) f(o);
    Object.values(o).forEach((x) => eachSourced(x, f));
  }
}

export interface SectionRow { name: string; records: number; facts: number; counts: Counts; gaps: number; conflicts: number }
export interface Gap { collection: string; id: string; label: string; field: string; need: string | null; route: string; confidence: Confidence }
export interface ConflictRow { collection: string; id: string; label: string; field: string; values: { value: string; source: string; confidence: Confidence; context?: string }[]; route: string }
export interface DomainRow { host: string; urls: number; facts: number; counts: Counts }
export interface Coverage { totals: { records: number; facts: number; counts: Counts; gaps: number; conflicts: number }; sections: SectionRow[]; gaps: Gap[]; conflicts: ConflictRow[]; domains: DomainRow[] }

/** Fields that legitimately hold null as "not applicable" rather than unknown are still listed: a null is a gap until sourced. */
function findGaps(collection: string, r: Obj, route: string): Gap[] {
  const out: Gap[] = [];
  const id = typeof r.id === 'string' ? r.id : labelOf(r);
  const base = { collection, id, label: labelOf(r), route };
  const walk = (o: Obj, prefix: string, owner: Obj) => {
    const own = 'source' in o ? o : owner;
    for (const [k, v] of Object.entries(o)) {
      if (k === 'conflicts' || k.endsWith('Conflicts')) continue;
      const field = prefix ? `${prefix}.${k}` : k;
      if (v === null) out.push({ ...base, field, need: typeof own.note === 'string' ? own.note : null, confidence: own.confidence as Confidence });
      else if (v && typeof v === 'object' && !Array.isArray(v)) walk(v as Obj, field, own);
    }
  };
  walk(r, '', r);
  return out;
}

function findConflicts(collection: string, r: Obj, route: string): ConflictRow[] {
  const out: ConflictRow[] = [];
  for (const k of ['conflicts', 'priceConflicts', 'productionConflicts']) {
    const list = r[k];
    if (!Array.isArray(list) || !list.length) continue;
    out.push({
      collection, id: typeof r.id === 'string' ? r.id : labelOf(r), label: labelOf(r), route,
      field: k === 'priceConflicts' ? 'price' : k === 'productionConflicts' ? 'production' : 'value',
      values: (list as Obj[]).map((c) => ({ value: c.value === null ? '—' : String(c.value), source: String(c.source), confidence: c.confidence as Confidence, ...(typeof c.context === 'string' ? { context: c.context } : {}) })),
    });
  }
  return out;
}

export function computeCoverage(collections: Record<string, Sourced[]>): Coverage {
  const sections: SectionRow[] = [], gaps: Gap[] = [], conflicts: ConflictRow[] = [];
  const domains = new Map<string, { urls: Set<string>; facts: number; counts: Counts }>();
  const totals = { records: 0, facts: 0, counts: zero(), gaps: 0, conflicts: 0 };
  for (const [name, recs] of Object.entries(collections)) {
    const row: SectionRow = { name, records: recs.length, facts: 0, counts: zero(), gaps: 0, conflicts: 0 };
    for (const rec of recs) {
      const r = rec as unknown as Obj;
      const route = routeFor(name, r);
      eachSourced(r, (s) => {
        const c = s.confidence as Confidence;
        if (!CONFIDENCES.includes(c)) return;
        row.facts++; row.counts[c]++;
        const h = hostOf(String(s.source));
        const d = domains.get(h) ?? { urls: new Set<string>(), facts: 0, counts: zero() };
        d.urls.add(String(s.source)); d.facts++; d.counts[c]++;
        domains.set(h, d);
      });
      const g = findGaps(name, r, route), cf = findConflicts(name, r, route);
      row.gaps += g.length; row.conflicts += cf.length;
      gaps.push(...g); conflicts.push(...cf);
    }
    sections.push(row);
    totals.records += row.records; totals.facts += row.facts; totals.gaps += row.gaps; totals.conflicts += row.conflicts;
    for (const c of CONFIDENCES) totals.counts[c] += row.counts[c];
  }
  const dom = [...domains.entries()].map(([host, d]) => ({ host, urls: d.urls.size, facts: d.facts, counts: d.counts }))
    .sort((a, b) => b.facts - a.facts || a.host.localeCompare(b.host));
  return { totals, sections, gaps, conflicts, domains: dom };
}

/** Share of facts at each level, as whole percentages that always add up to 100 (largest remainder). */
export function percentages(c: Counts): Counts {
  const total = CONFIDENCES.reduce((a, k) => a + c[k], 0);
  if (!total) return zero();
  const raw = CONFIDENCES.map((k) => (c[k] * 100) / total);
  const fl = raw.map(Math.floor);
  let left = 100 - fl.reduce((a, b) => a + b, 0);
  raw.map((x, i) => [x - fl[i], i] as const).sort((a, b) => b[0] - a[0]).forEach(([, i]) => { if (left > 0) { fl[i]++; left--; } });
  return { confirmed: fl[0], reported: fl[1], unverified: fl[2] };
}
