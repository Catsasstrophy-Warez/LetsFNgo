import { useId, useMemo, useRef, useState } from 'react';
import { useT, useUnits } from './SettingsContext';
import { ChartTable } from './ChartA11y';
import type { GpsSession } from '../lib/garage';
import { fmtLap, type LatLon } from '../lib/lapTimer';
import { MPH } from '../lib/gps';
import { SPEED_COLORS, fitMap, lapPoints, nearestIndex, sectorTable, speedBins } from '../lib/trackMap';
import { fmtQty, toDisplay, unitLabel } from '../lib/units';

const W = 400, H = 300;
/** Most rows in the data-table alternative (the full trace would be hundreds of rows). */
const TABLE_ROWS = 60;

/**
 * Stored GPS session drawn as an SVG map (equirectangular, auto-fitted, no map tiles or network), coloured by speed
 * with a colour-blind-safe palette, start/finish and sector lines, a lap selector, tap/scrub-to-inspect and a
 * data-table alternative, plus the per-sector times table with best and theoretical best.
 */
export function TrackMap({ gps }: { gps: GpsSession }) {
  const t = useT();
  const u = useUnits();
  const id = useId();
  const svgRef = useRef<SVGSVGElement>(null);
  const laps = gps.laps;
  const bestN = laps.filter((l) => l.valid).reduce<(typeof laps)[number] | null>((b, l) => (!b || l.seconds < b.seconds ? l : b), null)?.n ?? laps[0]?.n ?? null;
  const [lapN, setLapN] = useState<number | null>(bestN);
  const [sel, setSel] = useState<number | null>(null);
  const lap = laps.find((l) => l.n === lapN) ?? null;
  const pts = useMemo(() => (lap ? lapPoints(gps.trace, lap.startMs, lap.endMs) : []), [gps.trace, lap]);
  const lines = useMemo(() => [gps.line, ...gps.sectors], [gps.line, gps.sectors]);
  // Fit to the whole trace and the timing lines, so switching laps never re-scales the map.
  const proj = useMemo(() => fitMap([...gps.trace.map((p) => ({ lat: p[1], lon: p[2] })), ...lines.flatMap((l) => [l.a, l.b])], W, H, 16), [gps.trace, lines]);
  const sp = (mps: number) => toDisplay('speed', mps / MPH, u);
  const bins = useMemo(() => speedBins(pts.map((p) => p.mps)), [pts]);
  const xy = useMemo(() => (proj ? pts.map((p) => proj(p)) : []), [proj, pts]);
  const table = useMemo(() => sectorTable(laps), [laps]);
  const su = unitLabel('speed', u);
  const fmtSp = (mps: number) => `${Math.round(sp(mps))} ${su}`;
  const fmtD = (m: number) => fmtQty('distance', m / 1609.344, u, 2);

  if (!proj || !laps.length || gps.trace.length < 2) return null;

  // One path per speed bin keeps the SVG small: every segment takes the bin of its starting sample.
  const paths: string[] = SPEED_COLORS.map(() => '');
  for (let i = 1; i < xy.length; i++) {
    const b = bins.of(pts[i - 1].mps);
    paths[b] += `M${xy[i - 1].x.toFixed(1)} ${xy[i - 1].y.toFixed(1)}L${xy[i].x.toFixed(1)} ${xy[i].y.toFixed(1)}`;
  }
  const whole = gps.trace.map((p) => proj({ lat: p[1], lon: p[2] }));
  const P = (p: LatLon) => proj(p);
  const pick = (clientX: number, clientY: number) => {
    const svg = svgRef.current;
    const m = svg?.getScreenCTM?.();
    if (!svg || !m || !xy.length) return;
    const q = new DOMPoint(clientX, clientY).matrixTransform(m.inverse());
    setSel(nearestIndex(xy, q.x, q.y));
  };
  const cur = sel !== null && pts[sel] ? pts[sel] : null;
  const step = Math.max(1, Math.ceil(pts.length / TABLE_ROWS));

  return (
    <div className="sub track-map">
      <label>{t('tm.lap')}
        <select className="input" value={lapN ?? ''} onChange={(e) => { setLapN(Number(e.target.value)); setSel(null); }}>
          {laps.map((l) => <option key={l.n} value={l.n}>{t('lt.lap')} {l.n} · {fmtLap(l.seconds)}{l.n === bestN ? ' ★' : ''}{!l.valid ? ` (${t('lt.refused')})` : ''}</option>)}
        </select>
      </label>
      <figure className="chart">
        <figcaption className="chart-t">{t('tm.title')}</figcaption>
        <svg ref={svgRef} viewBox={`0 0 ${W} ${H}`} className="chart-svg tm-svg" role="img" aria-labelledby={`${id}-d`} onClick={(e) => pick(e.clientX, e.clientY)}>
          <desc id={`${id}-d`}>{t('tm.desc', { n: lap?.n ?? '', s: gps.sectors.length })}</desc>
          <polyline className="tm-all" points={whole.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')} />
          <polyline className="tm-under" points={xy.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ')} />
          {paths.map((d, i) => d && <path key={i} d={d} className={`tm-seg spd-${i}`} />)}
          {lines.map((l, i) => {
            const a = P(l.a), b = P(l.b);
            return (
              <g key={i} className={i ? 'tm-sector' : 'tm-sf'}>
                <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} />
                <text x={b.x + 4} y={b.y - 4} className="tm-label">{i ? `S${i}` : t('tm.sf')}</text>
              </g>
            );
          })}
          {cur && sel !== null && <circle className="tm-pt" cx={xy[sel].x} cy={xy[sel].y} r={6} />}
        </svg>
        <ul className="legend-list" aria-label={t('tm.legend', { u: su })}>
          {SPEED_COLORS.map((_, i) => (
            <li key={i}><span className={`tm-key spd-${i}`} aria-hidden="true" /> {Math.round(sp(bins.edges[i]))}–{Math.round(sp(bins.edges[i + 1]))} {su}{i === 0 ? ` (${t('tm.slow')})` : i === SPEED_COLORS.length - 1 ? ` (${t('tm.fast')})` : ''}</li>
          ))}
        </ul>
      </figure>
      {pts.length > 1 && (
        <label>{t('tm.scrub')}
          <input type="range" className="tm-range" min={0} max={pts.length - 1} value={sel ?? 0} onChange={(e) => setSel(Number(e.target.value))}
            aria-valuetext={cur ? t('tm.readout', { v: fmtSp(cur.mps), s: (cur.ms / 1000).toFixed(1), d: fmtD(cur.dM) }) : undefined} />
        </label>
      )}
      <p className="small" role="status" aria-live="polite">{cur ? t('tm.readout', { v: fmtSp(cur.mps), s: (cur.ms / 1000).toFixed(1), d: fmtD(cur.dM) }) : t('tm.tapHint')}</p>
      <ChartTable>
        <table className="tbl chart-tbl">
          <caption>{t('tm.tableCap', { n: lap?.n ?? '' })}</caption>
          <thead><tr><th scope="col">{t('tm.time')}</th><th scope="col">{t('tm.dist')}</th><th scope="col">{t('gps.speed')} ({su})</th></tr></thead>
          <tbody>{pts.filter((_, i) => i % step === 0 || i === pts.length - 1).map((p) => <tr key={p.ms}><td>{(p.ms / 1000).toFixed(1)} s</td><td>{fmtD(p.dM)}</td><td>{Math.round(sp(p.mps))}</td></tr>)}</tbody>
        </table>
      </ChartTable>
      <h3 className="sub">{t('tm.sectors')}</h3>
      {table.count < 2 ? <p className="muted small">{t('tm.noSectors')}</p> : (
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('tm.sectors')}>
          <table className="tbl">
            <caption className="sr-only">{t('tm.sectors')}</caption>
            <thead><tr><th scope="col">{t('lt.lap')}</th>{table.best.map((_, i) => <th key={i} scope="col">S{i + 1}</th>)}<th scope="col">{t('ga.time')}</th></tr></thead>
            <tbody>
              {table.rows.map((r) => (
                <tr key={r.n}>
                  <th scope="row">{r.n}{!r.valid ? ` (${t('lt.refused')})` : ''}</th>
                  {r.sectors.map((x, i) => { const isBest = r.valid && table.best[i] === x; return <td key={i} className={`mono${isBest ? ' tm-best' : ''}`}>{x.toFixed(3)}{isBest && <> ★<span className="sr-only"> {t('tm.bestSector')}</span></>}</td>; })}
                  <td className={`mono${r.valid && r.total === table.bestLap ? ' tm-best' : ''}`}>{fmtLap(r.total)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr><th scope="row">{t('tm.bestRow')}</th>{table.best.map((b, i) => <td key={i} className="mono">{b === null ? '—' : b.toFixed(3)}</td>)}<td className="mono">{table.bestLap === null ? '—' : fmtLap(table.bestLap)}</td></tr>
              <tr><th scope="row">{t('track.theoretical')}</th><td colSpan={table.count} /><td className="mono"><strong>{table.theoretical === null ? '—' : fmtLap(table.theoretical)}</strong></td></tr>
            </tfoot>
          </table>
        </div>
      )}
      <p className="note">{t('tm.note')}</p>
    </div>
  );
}
