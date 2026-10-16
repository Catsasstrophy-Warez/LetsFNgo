import { specs } from '../data/specs';
import type { SpecSystem } from '../data/types';
import { Cite, Conflicts, Note, fmt } from '../components/Facts';

const SYSTEMS: SpecSystem[] = ['Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy', 'Features'];

export default function Specs() {
  return (
    <>
      <h1>Specs</h1>
      <p className="lede">Mechanically identical for 2020, 2021 and 2022.</p>
      {SYSTEMS.map((sys) => (
        <section key={sys} className="card">
          <h2>{sys}</h2>
          <dl className="facts">
            {specs.filter((s) => s.system === sys).map((s) => (
              <div key={s.id} className={`fact ${s.value === null ? 'unknown' : ''}`}>
                <dt>{s.label}</dt>
                <dd>
                  <span className="val">{fmt(s.value, s.unit)}</span> <Cite c={s.confidence} url={s.source} />
                  {s.conflicts && <><div className="conflict-tag">Sources disagree</div><Conflicts values={s.conflicts} unit={s.unit} /></>}
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
