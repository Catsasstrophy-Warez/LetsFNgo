import { Cite } from './Facts';
import { useT } from './SettingsContext';
import type { TrackDef } from '../data/types';

/**
 * A track's sourced noise limit (research round 16) with its badge and source, plus other sourced event-day limits.
 * Tracks without a sourced limit say so; no value is ever filled in.
 */
export function TrackNoise({ track }: { track: TrackDef }) {
  const t = useT();
  const n = track.noiseLimit;
  if (!n || n.value === null) return <p className="muted small" data-testid="noise-limit">{t('noise.none')}</p>;
  return (
    <p className="small" data-testid="noise-limit">
      <strong>{t('noise.label', { db: n.value })}</strong>{n.context && <span className="muted"> · {n.context}</span>} <Cite c={n.confidence} url={n.source} />
      {n.conflicts && n.conflicts.length > 0 && (
        <span className="muted"> {t('noise.other')} {n.conflicts.map((c, i) => <span key={i}>{i ? '; ' : ''}{c.value} dB{c.context ? ` (${c.context})` : ''} <Cite c={c.confidence} url={c.source} /></span>)}</span>
      )}
    </p>
  );
}
