import { useState } from 'react';
import { Cite } from './Facts';
import { useT } from './SettingsContext';
import type { StartFinishLine } from '../data/types';
import { isOsmSource, linesForTrack, sourcedTimingLines, type TimingLine } from '../lib/lapTimer';

/**
 * "Use sourced line" for the chosen track: shown only when `lines` holds a sourced start/finish line for it, with the
 * line's source and confidence, and the OpenStreetMap credit when the source is OSM. Nothing renders otherwise
 * except a short note that the line must be set on-site.
 */
export function SourcedLinePicker({ trackId, lines, onUse }: { trackId: string; lines: StartFinishLine[]; onUse: (l: { line: TimingLine; sectors: TimingLine[] }, rec: StartFinishLine) => void }) {
  const t = useT();
  const list = trackId ? linesForTrack(lines, trackId) : [];
  const [cfg, setCfg] = useState(0);
  if (!trackId) return null;
  if (!list.length) return <p className="muted small">{t('sfl.none')}</p>;
  const rec = list[Math.min(cfg, list.length - 1)];
  return (
    <div className="sub sfl">
      {list.length > 1 && (
        <label>{t('sfl.config')}
          <select className="input" value={Math.min(cfg, list.length - 1)} onChange={(e) => setCfg(Number(e.target.value))}>
            {list.map((l, i) => <option key={l.id} value={i}>{l.configuration}</option>)}
          </select>
        </label>
      )}
      <p className="small">{t('sfl.available', { c: rec.configuration, s: rec.sectors.length })} <Cite c={rec.confidence} url={rec.source} /></p>
      {isOsmSource(rec.source) && <p className="small muted">{t('sfl.osm')} <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">© OpenStreetMap contributors</a></p>}
      <button type="button" className="btn ghost" onClick={() => onUse(sourcedTimingLines(rec), rec)}>{t('sfl.use')}</button>
    </div>
  );
}
