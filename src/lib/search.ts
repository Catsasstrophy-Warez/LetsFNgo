import { collections } from '../data';
import { load, save } from './storage';
import { routeFor } from './coverage';

export interface SearchHit { collection: string; title: string; text: string; route: string; source: string }


function flatten(v: unknown): string {
  if (v == null) return '';
  if (typeof v === 'object') return Object.entries(v as object).filter(([k]) => k !== 'source' && k !== 'swatch' && k !== 'originalUrl').map(([, x]) => flatten(x)).join(' ');
  return String(v);
}

const index = Object.entries(collections).flatMap(([collection, recs]) =>
  recs.map((r) => {
    const o = r as unknown as Record<string, unknown>;
    const title = String(o.label ?? o.name ?? o.title ?? o.number ?? o.item ?? o.stage ?? o.positions ?? o.text ?? o.description ?? collection);
    return { collection, title, text: flatten(r), route: routeFor(collection, o), source: r.source };
  }),
);

const TOOL = 'https://github.com/Catsasstrophy-Warez/LetsFNgo';
/** App tools are searchable too; they are not sourced records, so they link back to the project. */
const tools: SearchHit[] = [
  { title: 'Session Timer', text: 'stopwatch lap timer split track day drag day wake lock laps', route: '/timer' },
  { title: 'GPS Lap Timer', text: 'gps lap timer start finish line sectors delta ghost best lap circuit track day predictive speed trace gpx csv', route: '/laptimer' },
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
  { title: 'Service history report', text: 'resale report service history print pdf odometer recalls checklist buyer', route: '/report' },
  { title: "Buyer's guide", text: 'buyer buying used pre-purchase inspection checklist vin recalls asking price sanity check comprar usado inspeccion guia del comprador', route: '/buy' },
  { title: 'Market value', text: 'auction results market value price mileage bring a trailer mecum barrett-jackson median', route: '/market' },
  { title: 'Achievements', text: 'achievements milestones badges first track day drag passes miles', route: '/achievements' },
  { title: 'Calendar export', text: 'ics calendar export maintenance reminders ical google apple outlook', route: '/garage' },
  { title: 'Keyboard shortcuts', text: 'keyboard shortcuts hotkeys keys help', route: '/settings' },
  { title: 'Backup & restore', text: 'export import JSON backup restore reset', route: '/settings' },
  { title: 'Drag Strip Log', text: 'drag strip timeslip reaction time 60 ft 330 eighth quarter mile ET trap mph density altitude DA weather consistency', route: '/drag' },
  { title: 'Density altitude calculator', text: 'density altitude DA calculator temperature barometer pressure humidity elevation weather correction auto-fill open-meteo', route: '/drag' },
  { title: 'Fuel & Cost Log', text: 'fuel fill up gallons litres price mpg economy cost per mile E85 93 octane ownership cost', route: '/fuel' },
  { title: 'Color Visualizer', text: 'paint color visualizer stripes rarity production count code', route: '/visualizer' },
  { title: 'Print spec sheet', text: 'print spec sheet PDF printable', route: '/print' },
  { title: 'Trivia quiz', text: 'trivia quiz questions score game', route: '/quiz' },
  { title: 'Settings', text: 'settings units metric imperial km kg theme dark light export import reset data backup', route: '/settings' },
].map((t) => ({ ...t, collection: 'tools', source: TOOL }));

/* ---------- fuzzy ranked search ---------- */

/** Lower-case, strip diacritics (é → e), unify dashes/quotes, collapse whitespace. */
export function norm(s: string): string {
  return s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[\u2010-\u2015\u2212_]/g, '-').replace(/[\u2018\u2019]/g, "'").replace(/\s+/g, ' ').trim();
}
/** Alphanumerics only: "FL-2087", "fl 2087" and "FL2087" all become "fl2087". */
export const compact = (s: string) => norm(s).replace(/[^a-z0-9]/g, '');
const words = (s: string) => norm(s).split(/[^a-z0-9]+/).filter(Boolean);

/** Damerau–Levenshtein (optimal string alignment) distance, stopping early once it exceeds `max`. */
export function editDistance(a: string, b: string, max = 2): number {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  const d: number[][] = Array.from({ length: a.length + 1 }, (_, i) => [i, ...new Array<number>(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    let rowMin = Infinity;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
      rowMin = Math.min(rowMin, d[i][j]);
    }
    if (rowMin > max) return max + 1;
  }
  return d[a.length][b.length];
}

/** Allowed typos for a term: none under 4 letters, 1 up to 6, 2 from 7. */
const tolerance = (n: number) => (n < 4 ? 0 : n < 7 ? 1 : 2);

interface Doc { hit: SearchHit; title: string; titleWords: string[]; titleCompact: string; body: string; bodyWords: Set<string>; bodyCompact: string }
const docs: Doc[] = [...tools, ...index].map((hit) => {
  const body = norm(hit.text);
  return { hit, title: norm(hit.title), titleWords: words(hit.title), titleCompact: compact(hit.title), body, bodyWords: new Set(words(hit.text)), bodyCompact: compact(hit.text) };
});

/** Score one query term against one document (0 = no match). Title matches outrank body matches. */
function termScore(term: string, d: Doc): number {
  const c = compact(term);
  if (!c) return 0;
  let s = 0;
  if (d.titleWords.includes(c)) s = 12;
  else if (d.titleWords.some((w) => w.startsWith(c))) s = 9;
  else if (d.titleCompact.includes(c)) s = 7;
  else if (d.bodyWords.has(c)) s = 5;
  else if (c.length >= 2 && [...d.bodyWords].some((w) => w.startsWith(c))) s = 4;
  else if (c.length >= 3 && d.bodyCompact.includes(c)) s = 3;
  if (s) return s;
  const tol = tolerance(c.length);
  if (!tol) return 0;
  if (d.titleWords.some((w) => editDistance(c, w, tol) <= tol)) return 4;
  for (const w of d.bodyWords) if (editDistance(c, w, tol) <= tol) return 2;
  return 0;
}

export interface RankedHit extends SearchHit { score: number }

/** Ranked fuzzy search: every term must match (exactly, as a prefix/substring, or within the typo tolerance). */
export function rankedSearch(q: string, limit = 60): RankedHit[] {
  const nq = norm(q);
  const terms = nq.split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  const whole = compact(q);
  const out: RankedHit[] = [];
  for (const d of docs) {
    let score = 0;
    let all = true;
    for (const t of terms) { const s = termScore(t, d); if (!s) { all = false; break; } score += s; }
    // A spaced query that matches as one token ("fl 2087" → "fl2087") still counts.
    if (!all && terms.length > 1 && whole.length >= 4 && (d.titleCompact.includes(whole) || d.bodyCompact.includes(whole))) { all = true; score = d.titleCompact.includes(whole) ? 10 : 5; }
    if (!all) continue;
    if (d.title === nq) score += 20; else if (d.title.startsWith(nq)) score += 6;
    if (d.hit.collection === 'tools') score += 1;
    out.push({ ...d.hit, score });
  }
  return out.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title)).slice(0, limit);
}

export function search(q: string, limit = 40): SearchHit[] {
  return rankedSearch(q, limit);
}

/** Results grouped by collection, groups ordered by their best hit. */
export function groupHits(hits: RankedHit[]): { collection: string; hits: RankedHit[] }[] {
  const m = new Map<string, RankedHit[]>();
  for (const h of hits) { const g = m.get(h.collection); if (g) g.push(h); else m.set(h.collection, [h]); }
  return [...m.entries()].map(([collection, hs]) => ({ collection, hits: hs }));
}

/* ---------- recent searches (this device only) ---------- */
export const RECENT_KEY = 'gt500.recentSearches.v1';
export const MAX_RECENT = 8;
export function loadRecent(): string[] {
  const v = load<unknown>(RECENT_KEY, []);
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x.length <= 100).slice(0, MAX_RECENT) : [];
}
/** Put `q` first (case/diacritic-insensitive de-duplication). Returns the new list. */
export function pushRecent(q: string, list = loadRecent()): string[] {
  const t = q.trim().slice(0, 100);
  if (t.length < 2) return list;
  const next = [t, ...list.filter((x) => norm(x) !== norm(t))].slice(0, MAX_RECENT);
  save(RECENT_KEY, next);
  return next;
}
export const clearRecent = () => save(RECENT_KEY, []);
