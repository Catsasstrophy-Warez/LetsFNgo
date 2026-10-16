import type { Confidence, SourcedValue } from '../data/types';
import { tr } from '../lib/i18n';

export function Badge({ c }: { c: Confidence }) {
  return <span className={`badge badge-${c}`} title={tr('common.confidence', { c })}>{c}</span>;
}

export function hostOf(url: string): string {
  try { return new URL(url).hostname.replace(/^www\d?\.|^www-backend\./, ''); } catch { return url; }
}

export function Src({ url }: { url: string }) {
  return <a className="src" href={url} target="_blank" rel="noopener noreferrer">{hostOf(url)} ↗</a>;
}

/** Badge + source link. */
export function Cite({ c, url }: { c: Confidence; url: string }) {
  return <span className="cite"><Badge c={c} /> <Src url={url} /></span>;
}

export function fmt(v: number | string | null | undefined, unit?: string): string {
  if (v === null || v === undefined) return tr('common.unknown');
  const s = typeof v === 'number' ? v.toLocaleString('en-US') : v;
  return unit ? `${s} ${unit}` : s;
}

export const usd = (n: number | null) => (n === null ? tr('common.unknown') : `$${n.toLocaleString('en-US')}`);

export function Conflicts({ values, unit, money }: { values: SourcedValue[]; unit?: string; money?: boolean }) {
  return (
    <ul className="conflicts">
      {values.map((v, i) => (
        <li key={i}>
          <strong>{money && typeof v.value === 'number' ? usd(v.value) : fmt(v.value, unit)}</strong>
          {v.context && <span className="muted"> — {v.context}</span>} <Cite c={v.confidence} url={v.source} />
        </li>
      ))}
    </ul>
  );
}

export function Note({ children }: { children: React.ReactNode }) {
  return <p className="note">{children}</p>;
}
