import { specs } from '../data/specs';
import { colors } from '../data/colors';
import type { SpecSystem } from '../data/types';
import { Badge, fmt, hostOf } from '../components/Facts';
import { useUnits } from '../components/SettingsContext';
import { convertSpec, fmtQty } from '../lib/units';
import { loadGarage, toNum } from '../lib/garage';

const SYSTEMS: SpecSystem[] = ['Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy'];

export default function PrintSheet() {
  const u = useUnits();
  const g = loadGarage();
  const color = colors.find((c) => c.id === g.color);
  return (
    <article className="print-sheet">
      <div className="no-print btn-row">
        <button className="btn" onClick={() => window.print()}>Print / save as PDF</button>
        <span className="muted small">Optimized for letter/A4 paper. Navigation is hidden when printing.</span>
      </div>
      <h1>2020–2022 Shelby GT500 — Spec Sheet</h1>
      <section className="print-car">
        <h2>{g.nickname || 'My GT500'}</h2>
        <dl className="facts compact">
          <div className="fact"><dt>Year</dt><dd>{g.year || '—'}</dd></div>
          <div className="fact"><dt>Color</dt><dd>{color ? `${color.name}${color.code ? ` (${color.code})` : ''}` : g.color === 'other' ? 'Other' : '—'}</dd></div>
          <div className="fact"><dt>VIN</dt><dd className="mono">{g.vin || '—'}</dd></div>
          <div className="fact"><dt>Odometer</dt><dd>{toNum(g.odometer) === null ? '—' : fmtQty('distance', toNum(g.odometer), u)}</dd></div>
          <div className="fact"><dt>Mods</dt><dd>{g.mods.length ? g.mods.map((m) => m.title).join(', ') : 'None logged'}</dd></div>
        </dl>
      </section>
      <div className="print-cols">
        {SYSTEMS.map((sys) => (
          <section key={sys} className="print-sys">
            <h3>{sys}</h3>
            <table className="print-tbl"><tbody>
              {specs.filter((s) => s.system === sys).map((s) => {
                const c = s.value === null ? null : convertSpec(s.value, s.unit, u);
                return <tr key={s.id}><th>{s.label}</th><td>{c ? fmt(c.value, c.unit) : 'Unknown'} <Badge c={s.confidence} /> <span className="print-src">{hostOf(s.source)}</span></td></tr>;
              })}
            </tbody></table>
          </section>
        ))}
      </div>
      <p className="small muted">Unofficial fan reference compiled from cited third-party sources; confidence shown per line. Not affiliated with Ford Motor Company or Shelby American. Verify with official documents.</p>
    </article>
  );
}
