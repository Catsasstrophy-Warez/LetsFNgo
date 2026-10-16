import type { GarageState, TrackSession } from './garage';
import type { Timeslip } from './drag';
import type { FillUp } from './fuel';
import { lapStats, parseLaps, formatLapTime } from './laptime';

export type EventKind = 'service' | 'mod' | 'track' | 'drag' | 'fuel';
export const KIND_LABEL: Record<EventKind, string> = { service: 'Service', mod: 'Mod', track: 'Track', drag: 'Drag', fuel: 'Fuel' };

export interface TimelineEvent { id: string; kind: EventKind; date: string; title: string; detail: string; cost: number | null }

const money = (s: string | undefined) => { const n = Number(String(s ?? '').replace(/[$,\s]/g, '')); return s && s.trim() && Number.isFinite(n) ? n : null; };
const ISO = /^\d{4}-\d{2}-\d{2}/;

/** Every dated entry across Garage service/mods, track, drag and fuel logs, newest first. Undated entries are skipped. */
export function buildTimeline(g: GarageState, track: TrackSession[], drag: Timeslip[], fuel: FillUp[]): TimelineEvent[] {
  const ev: TimelineEvent[] = [
    ...g.service.map((e) => ({ id: `s-${e.id}`, kind: 'service' as const, date: e.date, title: e.title, detail: [e.miles && `${e.miles} mi`, e.notes].filter(Boolean).join(' · '), cost: money(e.cost) })),
    ...g.mods.map((e) => ({ id: `m-${e.id}`, kind: 'mod' as const, date: e.date, title: e.title, detail: e.notes, cost: money(e.cost) })),
    ...track.map((t) => { const st = lapStats(parseLaps(t.laps).laps); return { id: `t-${t.id}`, kind: 'track' as const, date: t.date, title: t.track, detail: `${st.count} laps · best ${formatLapTime(st.best)}`, cost: null }; }),
    ...drag.map((d) => ({ id: `d-${d.id}`, kind: 'drag' as const, date: d.date, title: d.track || (d.gps ? 'GPS run' : 'Drag strip'),
      detail: d.gps ? `GPS estimate · ${d.gps.kind} ${d.gps.seconds.toFixed(2)} s` : d.quarterEt !== null ? `¼ ${d.quarterEt.toFixed(3)} s` : d.eighthEt !== null ? `⅛ ${d.eighthEt.toFixed(3)} s` : '', cost: null })),
    ...fuel.map((f) => ({ id: `f-${f.id}`, kind: 'fuel' as const, date: f.date, title: `${f.gallons.toFixed(2)} gal ${f.fuel === 'blend' ? `E${f.blend ?? '?'}` : f.fuel}`, detail: `${f.odometer.toLocaleString('en-US')} mi`, cost: Math.round(f.gallons * f.price * 100) / 100 })),
  ];
  return ev.filter((e) => ISO.test(e.date)).sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
}

export function filterTimeline(ev: TimelineEvent[], kinds: EventKind[], year: string | null): TimelineEvent[] {
  return ev.filter((e) => kinds.includes(e.kind) && (!year || e.date.startsWith(year)));
}

export interface YearSummary { year: string; counts: Record<EventKind, number>; spend: number; serviceSpend: number; modSpend: number; fuelSpend: number; gallons: number }

/** Per-year counts and spend (only entries that have a cost). Newest year first. */
export function yearlySummary(ev: TimelineEvent[], fuel: FillUp[] = []): YearSummary[] {
  const map = new Map<string, YearSummary>();
  const get = (y: string) => {
    if (!map.has(y)) map.set(y, { year: y, counts: { service: 0, mod: 0, track: 0, drag: 0, fuel: 0 }, spend: 0, serviceSpend: 0, modSpend: 0, fuelSpend: 0, gallons: 0 });
    return map.get(y)!;
  };
  for (const e of ev) {
    const y = get(e.date.slice(0, 4));
    y.counts[e.kind]++;
    if (e.cost !== null) {
      y.spend += e.cost;
      if (e.kind === 'service') y.serviceSpend += e.cost; else if (e.kind === 'mod') y.modSpend += e.cost; else if (e.kind === 'fuel') y.fuelSpend += e.cost;
    }
  }
  for (const f of fuel) if (ISO.test(f.date)) get(f.date.slice(0, 4)).gallons += f.gallons;
  return [...map.values()].sort((a, b) => b.year.localeCompare(a.year));
}
