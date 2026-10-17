import { useState, type KeyboardEvent, type ReactNode } from 'react';
import { tr } from '../lib/i18n';

/**
 * Data-table alternative for a chart: always in the accessibility tree (visually hidden), and shown on screen
 * with the toggle. One table, so screen readers never hear the data twice.
 */
export function ChartTable({ children }: { children: ReactNode }) {
  const [show, setShow] = useState(false);
  return (
    <div className="chart-tbl-box">
      <button type="button" className="link-btn small chart-tbl-btn no-print" aria-expanded={show} onClick={() => setShow((s) => !s)}>
        {show ? tr('chart.hideTable') : tr('chart.showTable')}
      </button>
      {/* Shown: a focusable scroll region (wide tables scroll on phones). Hidden: plain sr-only, no scrolling. */}
      <div className={show ? 'tbl-wrap' : 'sr-only'} data-testid="chart-table" {...(show ? { tabIndex: 0, role: 'region', 'aria-label': tr('chart.table') } : {})}>{children}</div>
    </div>
  );
}

/**
 * Props for one keyboard-focusable chart point using a roving tabindex: only the active point is in the tab order;
 * arrow keys / Home / End move between points; focus and hover both drive the tooltip.
 */
export function pointProps(i: number, n: number, active: number, label: string, set: (i: number | null) => void) {
  const move = (e: KeyboardEvent<SVGGElement>) => {
    const to = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? Math.min(n - 1, i + 1) : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? Math.max(0, i - 1) : e.key === 'Home' ? 0 : e.key === 'End' ? n - 1 : null;
    if (to === null) return;
    e.preventDefault();
    const svg = e.currentTarget.ownerSVGElement;
    (svg?.querySelector(`[data-pt="${to}"]`) as SVGGElement | null)?.focus();
  };
  return {
    'data-pt': i, tabIndex: i === active ? 0 : -1, role: 'img', 'aria-label': label, className: 'chart-pt',
    onFocus: () => set(i), onMouseEnter: () => set(i), onTouchStart: () => set(i), onKeyDown: move,
  };
}

/** SVG tooltip box anchored at (x, y), kept inside the viewBox. */
export function ChartTip({ x, y, text, W, top = 0 }: { x: number; y: number; text: string; W: number; top?: number }) {
  const w = Math.min(W - 8, text.length * 10 + 20), h = 32;
  const left = Math.max(4, Math.min(W - w - 4, x - w / 2));
  const ty = y - h - 12 < top ? y + 14 : y - h - 12;
  return (
    <g className="chart-tip" aria-hidden="true" pointerEvents="none">
      <rect x={left} y={ty} width={w} height={h} rx={6} />
      <text x={left + w / 2} y={ty + 22} textAnchor="middle">{text}</text>
    </g>
  );
}
