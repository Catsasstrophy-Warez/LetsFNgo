/**
 * Track day planner: upcoming events (date, track from the sourced tracks list or a custom name, run group,
 * organiser), packing-list templates and an RFC 5545 .ics export. Stored on this device and in backups (schema v9).
 */
import { CRLF, escapeText, foldLine, icsDate, icsStamp } from './ics';
import { load, save } from './storage';

export const TRACKDAYS_KEY = 'gt500.trackdays.v1';
export const MAX_EVENTS = 100;
export const MAX_TEXT = 200;
export const MAX_PACK = 60;

export type PackTemplate = 'hpde' | 'drag' | 'autox';
/** Generic packing items (owner checklists, not sourced facts). */
export const PACK_TEMPLATES: Record<PackTemplate, string[]> = {
  hpde: ['helmet', 'license', 'techForm', 'tirePressureGauge', 'torqueWrench', 'brakeFluid', 'oilQuart', 'numbers', 'tape', 'water', 'sunscreen', 'chair', 'gloves', 'phoneMount'],
  drag: ['helmet', 'license', 'techForm', 'tirePressureGauge', 'numbers', 'water', 'chair', 'towels'],
  autox: ['helmet', 'license', 'tirePressureGauge', 'numbers', 'tape', 'water', 'chair', 'sunscreen'],
};

export interface PackItem { id: string; label: string; done: boolean }
export interface TrackDay {
  id: string; date: string; /** Last day (multi-day events); '' for one day. */ endDate: string;
  trackId: string; /** Custom name when the track is not in the list, else the list name. */ track: string;
  group: string; org: string; notes: string; pack: PackItem[];
}

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const s = (v: unknown, max = MAX_TEXT) => (typeof v === 'string' ? v.slice(0, max) : '');
const validDate = (d: string) => DATE.test(d) && !Number.isNaN(Date.parse(`${d}T00:00:00Z`)) && new Date(`${d}T00:00:00Z`).toISOString().startsWith(d);

export function normPack(v: unknown): PackItem | null {
  if (!v || typeof v !== 'object') return null;
  const o = v as Record<string, unknown>;
  if (typeof o.id !== 'string' || !o.id || typeof o.label !== 'string' || !o.label.trim()) return null;
  return { id: o.id.slice(0, 40), label: o.label.slice(0, 120), done: o.done === true };
}
export function normTrackDay(v: unknown): TrackDay | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  if (typeof o.id !== 'string' || !o.id || typeof o.date !== 'string' || !validDate(o.date) || typeof o.track !== 'string' || !o.track.trim()) return null;
  const end = typeof o.endDate === 'string' && validDate(o.endDate) && o.endDate >= o.date ? o.endDate : '';
  // Repeated item ids would make one checkbox toggle several items; keep the first of each.
  const ids = new Set<string>();
  const pack = Array.isArray(o.pack) ? o.pack.map(normPack).filter((x): x is PackItem => !!x && !ids.has(x.id) && !!ids.add(x.id)).slice(0, MAX_PACK) : [];
  return { id: o.id.slice(0, 40), date: o.date, endDate: end, trackId: s(o.trackId, 80), track: s(o.track), group: s(o.group, 60), org: s(o.org), notes: s(o.notes, 1000), pack };
}
export const loadTrackDays = (): TrackDay[] => {
  const v = load<unknown>(TRACKDAYS_KEY, []);
  const ids = new Set<string>();
  return Array.isArray(v) ? v.map(normTrackDay).filter((x): x is TrackDay => !!x && !ids.has(x.id) && !!ids.add(x.id)) : [];
};
export const saveTrackDays = (l: TrackDay[]) => save(TRACKDAYS_KEY, sortDays(l).slice(0, MAX_EVENTS));
export const sortDays = (l: TrackDay[]) => l.slice().sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));

/** Upcoming (ends today or later) and past events, each sorted (past newest first). */
export function splitDays(l: TrackDay[], today: string) {
  const end = (d: TrackDay) => d.endDate || d.date;
  return { upcoming: sortDays(l.filter((d) => end(d) >= today)), past: sortDays(l.filter((d) => end(d) < today)).reverse() };
}
/** Whole days from `today` to the event start (negative when started). */
export const daysUntil = (d: string, today: string) => Math.round((Date.parse(`${d}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000);

let n = 0;
export const packFrom = (labels: string[]): PackItem[] => labels.map((label) => ({ id: `pk${Date.now().toString(36)}${(n++).toString(36)}`, label, done: false }));

const nextDay = (iso: string) => { const d = new Date(`${iso}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); };

/** All-day VEVENTs (DTEND is exclusive, so a one-day event ends the next day). */
export function trackDaysToIcs(list: TrackDay[], stamp = new Date()): string {
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//GT500 Companion//Track days//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH', `X-WR-CALNAME:${escapeText('GT500 track days')}`];
  for (const d of sortDays(list)) {
    const desc = [d.org && `Organizer: ${d.org}`, d.group && `Run group: ${d.group}`, d.notes, d.pack.length ? `Packing: ${d.pack.filter((p) => !p.done).map((p) => p.label).join(', ') || 'all packed'}` : ''].filter(Boolean).join('\n');
    lines.push('BEGIN:VEVENT', `UID:${escapeText(`${d.id}-${icsDate(d.date)}`)}@gt500-companion`, `DTSTAMP:${icsStamp(stamp)}`,
      `DTSTART;VALUE=DATE:${icsDate(d.date)}`, `DTEND;VALUE=DATE:${icsDate(nextDay(d.endDate || d.date))}`,
      `SUMMARY:${escapeText(`Track day: ${d.track}${d.group ? ` (${d.group})` : ''}`)}`,
      ...(desc ? [`DESCRIPTION:${escapeText(desc)}`] : []), `LOCATION:${escapeText(d.track)}`, 'TRANSP:OPAQUE', 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.map(foldLine).join(CRLF) + CRLF;
}
