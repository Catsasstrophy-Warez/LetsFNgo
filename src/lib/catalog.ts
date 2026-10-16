import type { Confidence, FpCatalogItem, HistoryEvent, Milestone, ModelYear, ShelbyEdition } from '../data/types';

/** Filters shared by the round-8 catalog pages. `null` means "any". */
export interface EditionFilter { year: ModelYear | null; confidence: Confidence | null; streetLegalOnly: boolean }
export const DEFAULT_EDITION_FILTER: EditionFilter = { year: null, confidence: null, streetLegalOnly: false };

/** Street-legal-only keeps editions a source does not call off-road only (null = not stated is kept). */
export const filterEditions = (list: ShelbyEdition[], f: EditionFilter) => list.filter((e) =>
  (f.year === null || e.modelYears.includes(f.year)) && (f.confidence === null || e.confidence === f.confidence) && (!f.streetLegalOnly || e.streetLegal !== false));

export interface FpFilter { q: string; year: ModelYear | null; explicitOnly: boolean; category: FpCatalogItem['category'] | null }
export const DEFAULT_FP_FILTER: FpFilter = { q: '', year: null, explicitOnly: false, category: null };
const squash = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
/** Dash-insensitive search over M-number and name, plus year/fitment/category filters. */
export const filterFp = (list: FpCatalogItem[], f: FpFilter) => {
  const q = squash(f.q);
  return list.filter((p) => (!q || squash(p.number).includes(q) || squash(p.name).includes(q))
    && (f.year === null || p.fitmentYears.includes(f.year)) && (!f.explicitOnly || p.fitmentExplicit) && (f.category === null || p.category === f.category));
};

/** One row of the history timeline. */
export type TimelineItem =
  | { kind: 'milestone'; id: string; date: string | null; item: Milestone }
  | { kind: 'event'; id: string; date: string | null; item: HistoryEvent };

/** Events and milestones merged in date order (YYYY < YYYY-MM < YYYY-MM-DD within a year); undated items last. */
export function historyTimeline(events: HistoryEvent[], milestones: Milestone[], show: 'all' | 'milestone' | 'event' = 'all'): TimelineItem[] {
  const items: TimelineItem[] = [
    ...(show === 'event' ? [] : milestones.map((m) => ({ kind: 'milestone' as const, id: m.id, date: m.date, item: m }))),
    ...(show === 'milestone' ? [] : events.map((e) => ({ kind: 'event' as const, id: e.id, date: e.date, item: e }))),
  ];
  return items.sort((a, b) => (a.date === null ? (b.date === null ? 0 : 1) : b.date === null ? -1 : a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}
