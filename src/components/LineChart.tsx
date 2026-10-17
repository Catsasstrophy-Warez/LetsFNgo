import { useId, useState } from 'react';
import { tr } from '../lib/i18n';
import { ChartTable, ChartTip, pointProps } from './ChartA11y';

export interface Pt { label: string; value: number }

/**
 * Single-series SVG line chart. Colors come from theme tokens so it works in both themes.
 * Accessible: a labelled group with a text summary, keyboard-focusable points (roving tabindex, arrow keys) with a
 * tooltip and live readout, and a visually hidden data table that can be shown on screen.
 */
export function LineChart({ title, points, format, unit, lowerIsBetter = false, refLine }: {
  title: string; points: Pt[]; format: (v: number) => string; unit: string; lowerIsBetter?: boolean; refLine?: { value: number; label: string };
}) {
  const id = useId();
  const [hover, setHover] = useState<number | null>(null);
  if (points.length < 2) return <p className="muted small">{tr('chart.needTwo', { t: title })}</p>;
  const W = 640, H = 260, P = { l: 78, r: 16, t: 20, b: 36 };
  const vals = points.map((p) => p.value).concat(refLine ? [refLine.value] : []);
  let lo = Math.min(...vals), hi = Math.max(...vals);
  if (hi === lo) { hi += 1; lo -= 1; }
  const pad = (hi - lo) * 0.1; lo -= pad; hi += pad;
  const x = (i: number) => P.l + (i * (W - P.l - P.r)) / (points.length - 1);
  const y = (v: number) => P.t + ((hi - v) * (H - P.t - P.b)) / (hi - lo);
  const ticks = [0, 0.5, 1].map((f) => lo + f * (hi - lo));
  const best = lowerIsBetter ? Math.min(...points.map((p) => p.value)) : Math.max(...points.map((p) => p.value));
  const bestI = points.findIndex((p) => p.value === best);
  const first = points[0].value, last = points[points.length - 1].value;
  const summary = tr('chart.summary', { t: title, n: points.length, a: points[0].label, b: points[points.length - 1].label, f: `${format(first)} ${unit}`, l: `${format(last)} ${unit}`, best: `${format(best)} ${unit}` });
  const h = hover ?? points.length - 1;
  return (
    <figure className="chart">
      <figcaption className="chart-t">{title}</figcaption>
      <p className="chart-readout" aria-live="polite">{points[h].label}: <strong>{format(points[h].value)} {unit}</strong></p>
      <svg viewBox={`0 0 ${W} ${H}`} role="group" aria-label={title} aria-describedby={`${id}-d`} className="chart-svg" onMouseLeave={() => setHover(null)}>
        <desc id={`${id}-d`}>{summary}</desc>
        {ticks.map((t, i) => (
          <g key={i}>
            <line x1={P.l} x2={W - P.r} y1={y(t)} y2={y(t)} className="chart-grid" />
            <text x={P.l - 8} y={y(t) + 6} textAnchor="end" className="chart-axis">{format(t)}</text>
          </g>
        ))}
        <text x={P.l} y={H - 10} className="chart-axis">{points[0].label}</text>
        <text x={W - P.r} y={H - 8} textAnchor="end" className="chart-axis">{points[points.length - 1].label}</text>
        {refLine && <g><line x1={P.l} x2={W - P.r} y1={y(refLine.value)} y2={y(refLine.value)} className="chart-ref" /><text x={W - P.r} y={y(refLine.value) - 5} textAnchor="end" className="chart-axis">{refLine.label}</text></g>}
        <polyline points={points.map((p, i) => `${x(i)},${y(p.value)}`).join(' ')} className="chart-line" />
        {hover !== null && <line x1={x(hover)} x2={x(hover)} y1={P.t} y2={H - P.b} className="chart-grid" />}
        {points.map((p, i) => (
          <g key={i} {...pointProps(i, points.length, h, `${p.label}: ${format(p.value)} ${unit}${i === bestI ? tr('chart.best') : ''}`, setHover)} onBlur={() => setHover(null)}>
            <rect x={x(i) - 14} y={P.t} width={28} height={H - P.t - P.b} className="chart-hit" />
            <circle cx={x(i)} cy={y(p.value)} r={i === bestI ? 6 : 4} className={i === bestI ? 'chart-dot best' : 'chart-dot'} />
          </g>
        ))}
        {hover !== null && <ChartTip x={x(hover)} y={y(points[hover].value)} W={W} top={P.t} text={`${points[hover].label}: ${format(points[hover].value)} ${unit}`} />}
      </svg>
      <ChartTable>
        <table className="tbl chart-tbl"><caption>{title} — {tr('chart.table')}</caption><thead><tr><th scope="col">{tr('chart.entry')}</th><th scope="col">{unit}</th></tr></thead>
          <tbody>{points.map((p, i) => <tr key={i}><td>{p.label}</td><td>{format(p.value)}{i === bestI ? tr('chart.best') : ''}</td></tr>)}</tbody></table>
      </ChartTable>
    </figure>
  );
}
