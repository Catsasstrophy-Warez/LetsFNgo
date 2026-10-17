import { load, save } from './storage';
import { normDash, type DashLayout } from './validate';

/** Home cards that can be reordered or hidden. */
export const DASH_CARDS = [
  { id: 'garage', label: 'My Garage summary' },
  { id: 'stats', label: 'Headline specs' },
  { id: 'tools', label: 'Tools' },
  { id: 'legend', label: 'Confidence legend' },
  { id: 'reference', label: 'Reference sections' },
] as const;
export type DashCard = (typeof DASH_CARDS)[number]['id'];
export const DASH_IDS: readonly string[] = DASH_CARDS.map((c) => c.id);
export const DASH_KEY = 'gt500.home.v1';
export const DEFAULT_DASH: DashLayout = { order: [...DASH_IDS], hidden: [] };

export const normDashboard = (v: unknown) => normDash(v, DASH_IDS);
export const loadDash = (): DashLayout => normDashboard(load<unknown>(DASH_KEY, null)) ?? { ...DEFAULT_DASH, order: [...DEFAULT_DASH.order] };
export const saveDash = (d: DashLayout) => save(DASH_KEY, d);

/** Move a card up (-1) or down (+1). Out-of-range moves return the layout unchanged. */
export function moveCard(d: DashLayout, id: string, dir: -1 | 1): DashLayout {
  const i = d.order.indexOf(id), j = i + dir;
  if (i < 0 || j < 0 || j >= d.order.length) return d;
  const order = [...d.order];
  [order[i], order[j]] = [order[j], order[i]];
  return { ...d, order };
}
export const toggleCard = (d: DashLayout, id: string): DashLayout =>
  ({ ...d, hidden: d.hidden.includes(id) ? d.hidden.filter((x) => x !== id) : [...d.hidden, id] });
