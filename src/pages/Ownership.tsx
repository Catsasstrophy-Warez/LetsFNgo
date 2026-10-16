import { maintenance } from '../data/maintenance';
import { recalls, NHTSA_LOOKUP } from '../data/recalls';
import { Cite, Conflicts, Note, fmt } from '../components/Facts';
import type { MaintenanceItem, RecallIssue } from '../data/types';

const GROUPS: MaintenanceItem['group'][] = ['Fluids', 'Service', 'Warranty', 'Ownership'];

function Issue({ r }: { r: RecallIssue }) {
  return (
    <li>
      <div className="row-main"><span><span className="tag">{r.kind}</span> {r.title}</span>{r.years && <span className="muted">{r.years}</span>}</div>
      <p>{r.summary}</p>
      <div className="row-meta"><span className="muted">Campaign: {r.campaign ?? 'Unknown'}</span> <Cite c={r.confidence} url={r.source} /></div>
      {r.note && <Note>{r.note}</Note>}
    </li>
  );
}

export default function Ownership() {
  return (
    <>
      <h1>Ownership</h1>
      {GROUPS.map((g) => (
        <section key={g} className="card">
          <h2>{g === 'Fluids' ? 'Fluids & capacities' : g}</h2>
          <dl className="facts">
            {maintenance.filter((m) => m.group === g).map((m) => (
              <div key={m.id} className={`fact ${m.value === null ? 'unknown' : ''}`}><dt>{m.item}</dt><dd>
                <span className="val">{fmt(m.value, m.unit)}</span> <Cite c={m.confidence} url={m.source} />
                {m.conflicts && <><div className="conflict-tag">Sources disagree</div><Conflicts values={m.conflicts} /></>}
                {m.warning && <p className="err">⚠ {m.warning}</p>}
                {m.note && <Note>{m.note}</Note>}
              </dd></div>
            ))}
          </dl>
        </section>
      ))}
      <section className="card">
        <h2>Recalls, TSBs &amp; known issues</h2>
        <a className="btn" href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">Check your VIN on NHTSA ↗</a>
        <h3>GT500-specific items</h3>
        <ul className="rows">{recalls.filter((r) => r.kind !== 'nhtsa-recall').map((r) => <Issue key={r.id} r={r} />)}</ul>
      </section>
      <section className="card">
        <h2>Mustang 2020–22 NHTSA recalls — VIN check required for applicability</h2>
        <p className="muted">These campaigns cover the Mustang line by model year. NHTSA's listing does not say which apply to the GT500; enter your VIN at NHTSA to see open recalls for your car.</p>
        <ul className="rows">{recalls.filter((r) => r.kind === 'nhtsa-recall').map((r) => <Issue key={r.id} r={r} />)}</ul>
      </section>
    </>
  );
}
