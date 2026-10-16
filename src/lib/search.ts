import { collections } from '../data';

export interface SearchHit { collection: string; title: string; text: string; route: string; source: string }

const ROUTES: Record<string, string> = {
  specs: '/specs', modelYears: '/years', colors: '/colors', packages: '/packages', prices: '/packages',
  marketSales: '/packages', production: '/years', performance: '/performance', recalls: '/ownership',
  maintenance: '/ownership', vinPositions: '/vin', modStages: '/mods', competitors: '/compare',
  communities: '/community', partNumbers: '/parts', guides: '/guides', media: '/media', photos: '/media', audio: '/media', notes: '/sources',
};

function flatten(v: unknown): string {
  if (v == null) return '';
  if (typeof v === 'object') return Object.entries(v as object).filter(([k]) => k !== 'source' && k !== 'swatch').map(([, x]) => flatten(x)).join(' ');
  return String(v);
}

const index = Object.entries(collections).flatMap(([collection, recs]) =>
  recs.map((r) => {
    const o = r as unknown as Record<string, unknown>;
    const title = String(o.label ?? o.name ?? o.title ?? o.number ?? o.item ?? o.stage ?? o.positions ?? o.text ?? collection);
    return { collection, title, text: flatten(r), route: ROUTES[collection] ?? '/', source: r.source };
  }),
);

const TOOL = 'https://github.com/Catsasstrophy-Warez/LetsFNgo';
/** App tools are searchable too; they are not sourced records, so they link back to the project. */
const tools: SearchHit[] = [
  { title: 'Session Timer', text: 'stopwatch lap timer split track day drag day wake lock laps', route: '/timer' },
  { title: 'GPS Performance Meter', text: 'gps 0-60 60-130 quarter mile accelerometer performance meter estimate geolocation', route: '/gps' },
  { title: 'Ownership Timeline', text: 'timeline history service mods track drag fuel yearly summary spend', route: '/timeline' },
  { title: 'Year & Rival Compare', text: '2020 2021 2022 difference diff colors packages prices head-to-head rival competitor', route: '/diff' },
  { title: 'Welcome intro', text: 'onboarding intro setup first run year color vin units', route: '/welcome' },
  { title: 'Gear & Speed Calculator', text: 'gearing mph per gear rpm at speed final drive 3.73 tire size TR-9070 ratios calculator', route: '/gearing' },
  { title: 'Performance Tools', text: 'quarter mile ET trap speed estimator Hale Fox formula power to weight hp per ton calculator', route: '/tools' },
  { title: 'Build Planner', text: 'build plan mods cost total tune pulley Whipple exhaust planner', route: '/planner' },
  { title: 'Track Day Log', text: 'track day lap times sessions tire pressures best average theoretical Laguna Seca VIR log', route: '/track' },
  { title: 'Maintenance reminders', text: 'service reminders interval oil change due soon overdue odometer garage', route: '/garage' },
  { title: 'Share card', text: 'share card PNG garage spec card', route: '/garage' },
  { title: 'Backup & restore', text: 'export import JSON backup restore reset', route: '/settings' },
  { title: 'Drag Strip Log', text: 'drag strip timeslip reaction time 60 ft 330 eighth quarter mile ET trap mph density altitude DA weather consistency', route: '/drag' },
  { title: 'Density altitude calculator', text: 'density altitude DA calculator temperature barometer pressure humidity elevation weather correction', route: '/drag' },
  { title: 'Fuel & Cost Log', text: 'fuel fill up gallons litres price mpg economy cost per mile E85 93 octane ownership cost', route: '/fuel' },
  { title: 'Color Visualizer', text: 'paint color visualizer stripes rarity production count code', route: '/visualizer' },
  { title: 'Print spec sheet', text: 'print spec sheet PDF printable', route: '/print' },
  { title: 'Trivia quiz', text: 'trivia quiz questions score game', route: '/quiz' },
  { title: 'Settings', text: 'settings units metric imperial km kg theme dark light export import reset data backup', route: '/settings' },
].map((t) => ({ ...t, collection: 'tools', source: TOOL }));

export function search(q: string, limit = 40): SearchHit[] {
  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  return [...tools, ...index].filter((h) => { const t = (h.title + ' ' + h.text).toLowerCase(); return terms.every((x) => t.includes(x)); }).slice(0, limit);
}
