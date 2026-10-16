import { maintenance } from '../data/maintenance';
import { recalls, NHTSA_LOOKUP } from '../data/recalls';
import { Cite, Note, fmt } from '../components/Facts';

export default function Ownership() {
  return (
    <>
      <h1>Ownership</h1>
      <section className="card">
        <h2>Maintenance &amp; fluids</h2>
        <dl className="facts">
          {maintenance.map((m) => (
            <div key={m.id} className={`fact ${m.value === null ? 'unknown' : ''}`}><dt>{m.item}</dt><dd><span className="val">{fmt(m.value)}</span> <Cite c={m.confidence} url={m.source} />{m.note && <Note>{m.note}</Note>}</dd></div>
          ))}
        </dl>
      </section>
      <section className="card">
        <h2>Recalls, TSBs &amp; known issues</h2>
        <a className="btn" href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">Check your VIN on NHTSA ↗</a>
        <ul className="rows">
          {recalls.map((r) => (
            <li key={r.id}>
              <div className="row-main"><span><span className="tag">{r.kind}</span> {r.title}</span></div>
              <p>{r.summary}</p>
              <div className="row-meta"><span className="muted">Campaign: {r.campaign ?? 'Unknown'}</span> <Cite c={r.confidence} url={r.source} /></div>
              {r.note && <Note>{r.note}</Note>}
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
