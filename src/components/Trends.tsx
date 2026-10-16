import { useState } from 'react';
import { LineChart } from './LineChart';
import { stockPasses, type Timeslip } from '../lib/drag';
import type { TrackSession } from '../lib/garage';
import { formatLapTime, lapStats, parseLaps } from '../lib/laptime';
import { referenceLaps } from '../lib/refLaps';

/** ¼-mile ET per pass, oldest first, with the best sourced stock pass as a reference line. */
export function EtTrend({ slips }: { slips: Timeslip[] }) {
  const pts = slips.filter((s) => s.quarterEt !== null).map((s) => ({ label: s.date, value: s.quarterEt! }));
  const best = stockPasses().find((p) => p.record.id === 'best-stock');
  return <LineChart title="¼-mile ET trend" points={pts} format={(v) => v.toFixed(2)} unit="s" lowerIsBetter refLine={best ? { value: best.et, label: `Best sourced stock ${best.et}` } : undefined} />;
}

/** Best lap per session at one track (lap times are only comparable on the same circuit). */
export function LapTrend({ sessions }: { sessions: TrackSession[] }) {
  const tracks = [...new Set(sessions.map((s) => s.track.trim()).filter(Boolean))];
  const counts = tracks.map((t) => sessions.filter((s) => s.track.trim() === t).length);
  const [pick, setPick] = useState<string | null>(null);
  const track = pick && tracks.includes(pick) ? pick : tracks[counts.indexOf(Math.max(...counts, 0))] ?? '';
  const pts = sessions.filter((s) => s.track.trim() === track).sort((a, b) => a.date.localeCompare(b.date))
    .map((s) => ({ label: s.date, value: lapStats(parseLaps(s.laps).laps).best })).filter((p): p is { label: string; value: number } => p.value !== null);
  const ref = referenceLaps(track).find((r) => r.seconds !== null && r.record.confidence !== 'unverified');
  return (
    <>
      {tracks.length > 1 && (
        <label className="form-label">Track for lap trend
          <select className="input" value={track} onChange={(e) => setPick(e.target.value)}>{tracks.map((t) => <option key={t}>{t}</option>)}</select>
        </label>
      )}
      <LineChart title={`Best lap trend${track ? ` — ${track}` : ''}`} points={pts} format={(v) => formatLapTime(v, 2)} unit="lap" lowerIsBetter
        refLine={ref ? { value: ref.seconds!, label: `Sourced ${ref.record.result}` } : undefined} />
    </>
  );
}
