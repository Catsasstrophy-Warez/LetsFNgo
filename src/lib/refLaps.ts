import { performance } from '../data/performance';
import type { PerformanceRecord } from '../data/types';
import { parseLapTime } from './laptime';

const TRACKS: { key: string; match: RegExp; ids: string[] }[] = [
  { key: 'Laguna Seca', match: /laguna|weathertech raceway/i, ids: ['lap-laguna-mt', 'lap-laguna'] },
  { key: 'VIR', match: /\bvir\b|virginia international/i, ids: ['lap-vir-ll', 'lap-vir'] },
];

export const REFERENCE_TRACKS = TRACKS.map((t) => t.key);

export interface RefLap { record: PerformanceRecord; seconds: number | null }

/** Sourced stock-car reference laps for a user-typed track name, if it matches one we have. */
export function referenceLaps(track: string): RefLap[] {
  const t = TRACKS.find((x) => x.match.test(track));
  if (!t) return [];
  return t.ids.map((id) => performance.find((p) => p.id === id)!).filter(Boolean).map((record) => ({ record, seconds: parseLapTime(record.result.split(' ')[0]) }));
}
