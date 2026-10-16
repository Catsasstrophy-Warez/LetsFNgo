import { collections } from '../data';

export interface SearchHit { collection: string; title: string; text: string; route: string; source: string }

const ROUTES: Record<string, string> = {
  specs: '/specs', modelYears: '/years', colors: '/colors', packages: '/packages', prices: '/packages',
  marketSales: '/packages', production: '/years', performance: '/performance', recalls: '/ownership',
  maintenance: '/ownership', vinPositions: '/vin', modStages: '/mods', competitors: '/compare',
  communities: '/community', media: '/media', photos: '/media', audio: '/media', notes: '/sources',
};

function flatten(v: unknown): string {
  if (v == null) return '';
  if (typeof v === 'object') return Object.entries(v as object).filter(([k]) => k !== 'source' && k !== 'swatch').map(([, x]) => flatten(x)).join(' ');
  return String(v);
}

const index = Object.entries(collections).flatMap(([collection, recs]) =>
  recs.map((r) => {
    const o = r as unknown as Record<string, unknown>;
    const title = String(o.label ?? o.name ?? o.title ?? o.item ?? o.stage ?? o.positions ?? o.text ?? collection);
    return { collection, title, text: flatten(r), route: ROUTES[collection] ?? '/', source: r.source };
  }),
);

export function search(q: string, limit = 40): SearchHit[] {
  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  return index.filter((h) => { const t = (h.title + ' ' + h.text).toLowerCase(); return terms.every((x) => t.includes(x)); }).slice(0, limit);
}
