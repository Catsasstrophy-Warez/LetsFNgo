import { useId, useMemo, useState } from 'react';
import { useT, useUnits } from './SettingsContext';
import type { GpsSession } from '../lib/garage';
import { fmtLap, lapSpeedTrace, minMax, toGpx, traceCsv } from '../lib/lapTimer';
import { MPH } from '../lib/gps';
import { fmtQty, toDisplay, unitLabel } from '../lib/units';
import { downloadText } from '../lib/download';

/** Most laps overlaid at once. */
export const MAX_OVERLAY = 4;

/** Per-lap speed traces (speed vs distance) from a stored GPS session, lap overlay, min/max speeds and CSV/GPX export. */
export function GpsAnalysis({ gps, name, date }: { gps: GpsSession; name: string; date: string }) {
  const t = useT();
  const u = useUnits();
  const id = useId();
  const laps = gps.laps;
  const bestLapRec = laps.filter((l) => l.valid).reduce<(typeof laps)[number] | null>((b, l) => (!b || l.seconds < b.seconds ? l : b), null);
  const bestN = bestLapRec ? bestLapRec.n : null;
  const [sel, setSel] = useState<number[]>(() => (bestN !== null ? [bestN] : laps.slice(0, 1).map((l) => l.n)));
  const traces = useMemo(() => laps.map((l) => ({ lap: l, pts: lapSpeedTrace(gps.trace, l.startMs, l.endMs) })), [gps, laps]);
  const file = `gt500-${name.replace(/[^\w-]+/g, '-').slice(0, 40) || 'session'}-${date}`;
  const exportBtns = (
    <div className="btn-row">
      <button className="btn ghost" onClick={() => downloadText(traceCsv(gps.trace, laps.map((l) => ({ n: l.n, startMs: l.startMs, endMs: l.endMs }))), `${file}.csv`, 'text/csv;charset=utf-8')} disabled={!gps.trace.length}>{t('ga.csv')}</button>
      <button className="btn ghost" onClick={() => downloadText(toGpx(name, gps.startIso, gps.trace), `${file}.gpx`, 'application/gpx+xml')} disabled={!gps.trace.length}>{t('ga.gpx')}</button>
    </div>
  );
  if (!gps.trace.length) return <div className="sub"><p className="muted small">{t('ga.noTrace')}</p>{exportBtns}</div>;
  const shown = traces.filter((x) => sel.includes(x.lap.n) && x.pts.length > 1);
  const sp = (mps: number) => toDisplay('speed', mps / MPH, u);
  const all = shown.flatMap((x) => x.pts.map((p) => sp(p.mps)));
  const maxD = Math.max(1, ...shown.map((x) => x.pts[x.pts.length - 1].dM));
  const hi = Math.max(10, ...all) * 1.05;
  const W = 640, H = 240, P = { l: 48, r: 12, t: 12, b: 28 };
  const X = (d: number) => P.l + (d / maxD) * (W - P.l - P.r);
  const Y = (v: number) => P.t + (1 - v / hi) * (H - P.t - P.b);
  const toggle = (n: number) => setSel((s) => (s.includes(n) ? s.filter((x) => x !== n) : s.length >= MAX_OVERLAY ? s : [...s, n]));
  const su = unitLabel('speed', u);
  return (
    <div className="sub">
      <fieldset className="lap-pick">
        <legend>{t('ga.pick', { n: MAX_OVERLAY })}</legend>
        {laps.map((l) => (
          <label key={l.n} className="check"><input type="checkbox" checked={sel.includes(l.n)} onChange={() => toggle(l.n)} disabled={!sel.includes(l.n) && sel.length >= MAX_OVERLAY} />
            {t('lt.lap')} {l.n} · {fmtLap(l.seconds)}{l.n === bestN ? ` ★` : ''}{!l.valid ? ` (${t('lt.refused')})` : ''}</label>
        ))}
      </fieldset>
      {shown.length > 0 && (
        <figure className="chart">
          <figcaption className="chart-t">{t('ga.title')}</figcaption>
          <svg viewBox={`0 0 ${W} ${H}`} className="chart-svg" role="img" aria-labelledby={`${id}-d`}>
            <desc id={`${id}-d`}>{t('ga.desc', { n: shown.length })}</desc>
            {[0, 0.5, 1].map((f) => <g key={f}><line x1={P.l} x2={W - P.r} y1={Y(hi * f)} y2={Y(hi * f)} className="chart-grid" /><text x={P.l - 6} y={Y(hi * f) + 5} textAnchor="end" className="chart-axis">{Math.round(hi * f)}</text></g>)}
            <text x={W - P.r} y={H - 6} textAnchor="end" className="chart-axis">{fmtQty('distance', maxD / 1609.344, u, 2)}</text>
            {shown.map((x, k) => <polyline key={x.lap.n} className={`ga-line ga-c${k % 4}`} points={x.pts.map((p) => `${X(p.dM).toFixed(1)},${Y(sp(p.mps)).toFixed(1)}`).join(' ')} />)}
          </svg>
          <ul className="legend-list">{shown.map((x, k) => <li key={x.lap.n}><span className={`ga-key ga-c${k % 4}`} aria-hidden="true" /> {t('lt.lap')} {x.lap.n}</li>)}</ul>
        </figure>
      )}
      <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('ga.table')}>
        <table className="tbl chart-tbl">
          <caption>{t('ga.table')}</caption>
          <thead><tr><th scope="col">{t('lt.lap')}</th><th scope="col">{t('ga.time')}</th><th scope="col">{t('ga.min')} ({su})</th><th scope="col">{t('ga.max')} ({su})</th><th scope="col">{t('gps.accuracy')}</th></tr></thead>
          <tbody>{traces.map(({ lap, pts }) => { const mm = minMax(pts.map((p) => sp(p.mps))); return (
            <tr key={lap.n}><td>{lap.n}{!lap.valid ? ` (${t('lt.refused')})` : ''}</td><td className="mono">{fmtLap(lap.seconds)}</td><td>{mm ? mm.min.toFixed(0) : '—'}</td><td>{mm ? mm.max.toFixed(0) : '—'}</td><td>±{lap.accuracyM} m</td></tr>); })}</tbody>
        </table>
      </div>
      {exportBtns}
    </div>
  );
}
