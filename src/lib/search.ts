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

const TOOL = 'https://github.com/Catsasstrophy-Warez/LetsFNgo';
/** App tools are searchable too; they are not sourced records, so they link back to the project. */
const tools: SearchHit[] = [
  { title: 'Gear & Speed Calculator', text: 'gearing mph per gear rpm at speed final drive 3.73 tire size TR-9070 ratios calculator', route: '/gearing' },
  { title: 'Performance Tools', text: 'quarter mile ET trap speed estimator Hale Fox formula power to weight hp per ton calculator', route: '/tools' },
  { title: 'Build Planner', text: 'build plan mods cost total tune pulley Whipple exhaust planner', route: '/planner' },
  { title: 'Track Day Log', text: 'track day lap times sessions tire pressures best average theoretical Laguna Seca VIR log', route: '/track' },
  { title: 'Maintenance reminders', text: 'service reminders interval oil change due soon overdue odometer garage', route: '/garage' },
  { title: 'Backup & share card', text: 'export import JSON backup restore share card PNG garage', route: '/garage' },
].map((t) => ({ ...t, collection: 'tools', source: TOOL }));

export function search(q: string, limit = 40): SearchHit[] {
  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  return [...tools, ...index].filter((h) => { const t = (h.title + ' ' + h.text).toLowerCase(); return terms.every((x) => t.includes(x)); }).slice(0, limit);
}
