import { performance, performanceWarning } from '../data/performance';
import { Cite, Note } from '../components/Facts';

const CATS = [
  ['acceleration', 'Acceleration'], ['quarter-mile', 'Quarter mile'], ['lap', 'Lap times'], ['drag-record', 'Drag records (dated snapshots)'],
] as const;

export default function Performance() {
  return (
    <>
      <h1>Performance</h1>
      <div className="card warn">{performanceWarning.text} <Cite c={performanceWarning.confidence} url={performanceWarning.source} /></div>
      {CATS.map(([k, label]) => (
        <section key={k} className="card">
          <h2>{label}</h2>
          <ul className="rows">
            {performance.filter((p) => p.category === k).map((p) => (
              <li key={p.id}>
                <div className="row-main"><span>{p.label}</span><strong>{p.result}</strong></div>
                <div className="row-meta"><span className={`tag ${p.car === 'modified' ? 'tag-mod' : ''}`}>{p.car}</span> <span className="muted">{p.date ?? 'date unknown'}</span> <Cite c={p.confidence} url={p.source} /></div>
                {p.note && <Note>{p.note}</Note>}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}
