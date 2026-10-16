import { useId, useState } from 'react';
import type { ScatterPt } from '../lib/market';
import { tr } from '../lib/i18n';
import { ChartTable, ChartTip, pointProps } from './ChartA11y';

/**
 * Accessible single-series scatter plot (SVG, theme tokens). Optional vertical marker (e.g. "your car") and
 * horizontal reference line (e.g. a median). Points are keyboard-focusable (roving tabindex, arrow keys move in x order)
 * with a tooltip; a visually hidden data table can be shown on screen.
 */
export function ScatterChart({ title, points, fmtX, fmtY, xLabel, yLabel, marker, refY, tableLabel, empty }: {
  title: string; points: ScatterPt[]; fmtX: (v: number) => string; fmtY: (v: number) => string; xLabel: string; yLabel: string;
  marker?: { x: number; label: string }; refY?: { y: number; label: string }; tableLabel: string; empty: string;
}) {
  const id = useId();
  const [hover, setHover] = useState<number | null>(null);
  if (points.length === 0) return <p className="muted small">{title}: {empty}</p>;
  const W = 640, H = 300, P = { l: 92, r: 18, t: 18, b: 52 };
  const xs = points.map((p) => p.x).concat(marker ? [marker.x] : []);
  const ys = points.map((p) => p.y).concat(refY ? [refY.y] : []);
  let x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  if (x1 === x0) { x0 -= 1; x1 += 1; }
  if (y1 === y0) { y0 -= 1; y1 += 1; }
  const px = (x1 - x0) * 0.06, py = (y1 - y0) * 0.1;
  // Padding never pushes a non-negative axis (mileage, price) below zero.
  x0 = Math.min(...xs) >= 0 ? Math.max(0, x0 - px) : x0 - px; x1 += px;
  y0 = Math.min(...ys) >= 0 ? Math.max(0, y0 - py) : y0 - py; y1 += py;
  const sx = (v: number) => P.l + ((v - x0) * (W - P.l - P.r)) / (x1 - x0);
  const sy = (v: number) => P.t + ((y1 - v) * (H - P.t - P.b)) / (y1 - y0);
  const yt = [0, 0.5, 1].map((f) => y0 + f * (y1 - y0));
  const xt = [0, 0.5, 1].map((f) => x0 + f * (x1 - x0));
  const sorted = [...points].sort((a, b) => a.x - b.x);
  const summary = `${tr('chart.scatterSummary', { t: title, n: points.length, y: yLabel, lo: fmtY(Math.min(...points.map((p) => p.y))), hi: fmtY(Math.max(...points.map((p) => p.y))) })}${marker ? ` ${marker.label}.` : ''}`;
  const h = hover !== null ? sorted[hover] ?? null : null;
  return (
    <figure className="chart">
      <figcaption className="chart-t">{title}</figcaption>
      <p className="chart-readout" aria-live="polite">{h ? <>{h.label}: <strong>{fmtY(h.y)}</strong></> : `${points.length} · ${xLabel} / ${yLabel}`}</p>
      <svg viewBox={`0 0 ${W} ${H}`} role="group" aria-label={title} aria-describedby={`${id}-d`} className="chart-svg" onMouseLeave={() => setHover(null)}>
        <desc id={`${id}-d`}>{summary}</desc>
        {yt.map((v, i) => <g key={`y${i}`}><line x1={P.l} x2={W - P.r} y1={sy(v)} y2={sy(v)} className="chart-grid" /><text x={P.l - 8} y={sy(v) + 6} textAnchor="end" className="chart-axis">{fmtY(v)}</text></g>)}
        {xt.map((v, i) => <text key={`x${i}`} x={sx(v)} y={H - 26} textAnchor={i === 0 ? 'start' : i === 2 ? 'end' : 'middle'} className="chart-axis">{fmtX(v)}</text>)}
        <text x={(P.l + W - P.r) / 2} y={H - 4} textAnchor="middle" className="chart-axis">{xLabel}</text>
        {refY && <g><line x1={P.l} x2={W - P.r} y1={sy(refY.y)} y2={sy(refY.y)} className="chart-ref" /><text x={W - P.r} y={sy(refY.y) - 6} textAnchor="end" className="chart-axis">{refY.label}</text></g>}
        {marker && <g><line x1={sx(marker.x)} x2={sx(marker.x)} y1={P.t} y2={H - P.b} className="chart-mark" /><text x={Math.min(sx(marker.x) + 6, W - P.r)} y={P.t + 16} textAnchor={sx(marker.x) > W - 160 ? 'end' : 'start'} className="chart-axis chart-mark-t">{marker.label}</text></g>}
        {sorted.map((p, i) => (
          <g key={p.id} {...pointProps(i, sorted.length, hover ?? 0, `${p.label}: ${fmtY(p.y)}`, setHover)} onBlur={() => setHover(null)}>
            <circle cx={sx(p.x)} cy={sy(p.y)} r={hover === i ? 8 : 6} className={hover === i ? 'chart-dot best' : 'chart-dot'} />
          </g>
        ))}
        {h && <ChartTip x={sx(h.x)} y={sy(h.y)} W={W} top={P.t} text={`${fmtX(h.x)} · ${fmtY(h.y)}`} />}
      </svg>
      <ChartTable>
        <table className="tbl chart-tbl"><caption>{title} — {tableLabel}</caption><thead><tr><th scope="col">{xLabel}</th><th scope="col">{yLabel}</th></tr></thead>
          <tbody>{sorted.map((p) => <tr key={p.id}><td>{p.label}</td><td>{fmtY(p.y)}</td></tr>)}</tbody></table>
      </ChartTable>
    </figure>
  );
}
