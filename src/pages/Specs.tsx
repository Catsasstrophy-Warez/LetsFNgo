import { specs } from '../data/specs';
import type { SpecSystem } from '../data/types';
import { Cite, Note, fmt } from '../components/Facts';
import { useUnits } from '../components/SettingsContext';
import { convertSpec, type Units } from '../lib/units';
import type { SourcedValue } from '../data/types';

const show = (v: SourcedValue['value'], unit: string | undefined, u: Units) => { if (v === null) return fmt(v); const c = convertSpec(v, unit, u); return fmt(c.value, c.unit); };

const SYSTEMS: SpecSystem[] = ['Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy', 'Features'];

export default function Specs() {
  const u = useUnits();
  return (
    <>
      <h1>Specs</h1>
      <p className="lede">Mechanically identical for 2020, 2021 and 2022. Units follow your <a href="#/settings">setting</a>; a <a href="#/print">print-friendly sheet</a> is available.</p>
      {SYSTEMS.map((sys) => (
        <section key={sys} className="card">
          <h2>{sys}</h2>
          <dl className="facts">
            {specs.filter((s) => s.system === sys).map((s) => (
              <div key={s.id} className={`fact ${s.value === null ? 'unknown' : ''}`}>
                <dt>{s.label}</dt>
                <dd>
                  <span className="val">{show(s.value, s.unit, u)}</span> <Cite c={s.confidence} url={s.source} />
                  {s.conflicts && <><div className="conflict-tag">Sources disagree</div><ul className="conflicts">{s.conflicts.map((v, i) => <li key={i}><strong>{show(v.value, s.unit, u)}</strong>{v.context && <span className="muted"> — {v.context}</span>} <Cite c={v.confidence} url={v.source} /></li>)}</ul></>}
                  {s.note && <Note>{s.note}</Note>}
                </dd>
              </div>
            ))}
          </dl>
        </section>
      ))}
    </>
  );
}
