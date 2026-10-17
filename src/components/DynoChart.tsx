import { useId, useState } from 'react';
import type { DynoPull } from '../lib/dyno';

const SERIES = ['var(--accent)', 'var(--accent-2)', 'var(--ok)', 'var(--warn)', 'var(--muted)'];

import { tr } from '../lib/i18n';
import { ChartTable, ChartTip, pointProps } from './ChartA11y';

/**
 * Overlay of dyno curves: power solid, torque dashed, one color per pull (max 5).
 * A labelled group with a text summary; every power point is keyboard-focusable (roving tabindex, arrow keys) with
 * a tooltip, and a visually hidden data table per pull can be shown on screen.
 */
export function DynoChart({ pulls, label }: { pulls: DynoPull[]; label: (p: DynoPull) => string }) {
  const id = useId();
  const [hover, setHover] = useState<number | null>(null);
  const ps = pulls.filter((p) => p.curve.length >= 2).slice(0, SERIES.length);
  if (!ps.length) return <p className="muted small">{tr('dynochart.empty')}</p>;
  const W = 640, H = 300, P = { l: 64, r: 16, t: 16, b: 40 };
  const all = ps.flatMap((p) => p.curve);
  const rpms = all.map((c) => c.rpm);
  const vals = all.flatMap((c) => [c.hp, c.tq]).filter((x): x is number => x !== null);
  const r0 = Math.min(...rpms), r1 = Math.max(...rpms) === r0 ? r0 + 1 : Math.max(...rpms);
  const hi = Math.max(...vals, 1) * 1.08;
  const x = (r: number) => P.l + ((r - r0) * (W - P.l - P.r)) / (r1 - r0);
  const y = (v: number) => P.t + ((hi - v) * (H - P.t - P.b)) / hi;
  const line = (p: DynoPull, k: 'hp' | 'tq') => p.curve.filter((c) => c[k] !== null).map((c) => `${x(c.rpm).toFixed(1)},${y(c[k]!).toFixed(1)}`).join(' ');
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * hi);
  const summary = ps.map((p) => {
    const hp = Math.max(...p.curve.map((c) => c.hp ?? 0)), tq = Math.max(...p.curve.map((c) => c.tq ?? 0));
    return tr('dynochart.peak', { l: label(p), hp: hp.toFixed(0), tq: tq ? `, ${tq.toFixed(0)} lb-ft` : '' });
  }).join('; ');
  // Focusable points: each pull's power readings (torque where a row has no power), in pull then rpm order.
  const pts = ps.flatMap((p, pi) => p.curve.filter((c) => c.hp !== null || c.tq !== null).map((c) => ({ pi, rpm: c.rpm, v: (c.hp ?? c.tq)!, kind: c.hp !== null ? 'whp' : 'lb-ft', tq: c.tq, name: label(p) })));
  const tip = (q: (typeof pts)[number]) => `${q.name} · ${q.rpm} rpm: ${q.v} ${q.kind}${q.kind === 'whp' && q.tq !== null ? `, ${q.tq} lb-ft` : ''}`;
  const hp = hover !== null ? pts[hover] : null;
  return (
    <figure className="chart">
      <figcaption className="chart-t">{tr('dynochart.title')}</figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="group" aria-label={tr('dynochart.title')} aria-describedby={`${id}-d`} className="chart-svg" onMouseLeave={() => setHover(null)}>
        <desc id={`${id}-d`}>{tr('dynochart.desc', { n: ps.length, a: r0, b: r1, s: summary })}</desc>
        {ticks.map((t, i) => <g key={i}><line x1={P.l} x2={W - P.r} y1={y(t)} y2={y(t)} className="chart-grid" /><text x={P.l - 8} y={y(t) + 6} textAnchor="end" className="chart-axis">{t.toFixed(0)}</text></g>)}
        <text x={P.l} y={H - 10} className="chart-axis">{r0} rpm</text>
        <text x={W - P.r} y={H - 10} textAnchor="end" className="chart-axis">{r1} rpm</text>
        {ps.map((p, i) => (
          <g key={p.id} style={{ stroke: SERIES[i] }} fill="none" strokeWidth={2.5}>
            <polyline points={line(p, 'hp')} />
            <polyline points={line(p, 'tq')} strokeDasharray="7 5" />
          </g>
        ))}
        {pts.map((q, i) => (
          <g key={i} {...pointProps(i, pts.length, hover ?? 0, tip(q), setHover)} onBlur={() => setHover(null)}>
            <circle cx={x(q.rpm)} cy={y(q.v)} r={hover === i ? 6 : 3} className="chart-dot" style={{ fill: SERIES[q.pi] }} />
          </g>
        ))}
        {hp && <ChartTip x={x(hp.rpm)} y={y(hp.v)} W={W} top={P.t} text={tip(hp)} />}
      </svg>
      <ul className="legend-list">
        {ps.map((p, i) => <li key={p.id}><span className="swatch-line" style={{ background: SERIES[i] }} aria-hidden /> {label(p)}</li>)}
      </ul>
      <ChartTable>
        {ps.map((p) => (
          <table className="tbl chart-tbl" key={p.id}><caption>{label(p)} — {tr('chart.table')}</caption><thead><tr><th scope="col">rpm</th><th scope="col">whp</th><th scope="col">lb-ft</th></tr></thead>
            <tbody>{p.curve.map((c, i) => <tr key={i}><td>{c.rpm}</td><td>{c.hp ?? '—'}</td><td>{c.tq ?? '—'}</td></tr>)}</tbody></table>
        ))}
      </ChartTable>
    </figure>
  );
}
