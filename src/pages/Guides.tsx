import { Link } from 'react-router';
import { Badge, Note } from '../components/Facts';
import { guides } from '../data/guides';

export default function Guides() {
  const ready = guides.filter((g) => g.status === 'ready');
  const planned = guides.filter((g) => g.status === 'planned');
  return (
    <>
      <h1>How-to Guides</h1>
      <p className="lede">Step-by-step checklists built only from sourced facts. Every step shows its own source and confidence, and a guide is never rated above its weakest step. These say what the sources say; they are not workshop manuals.</p>
      <ul className="rows">
        {ready.map((g) => (
          <li key={g.id}>
            <div className="row-main"><Link to={`/guides/${g.id}`}><strong>{g.title}</strong></Link> <Badge c={g.confidence} /></div>
            <p className="muted small">{g.summary} · {g.steps.length} steps · {g.appliesTo}</p>
          </li>
        ))}
      </ul>
      <section className="card">
        <h2>Planned (not yet sourced)</h2>
        <ul className="rows">
          {planned.map((g) => <li key={g.id}><strong>{g.title}</strong><p className="muted small">{g.summary}</p></li>)}
        </ul>
      </section>
      <Note>Want to add a guide? Every step needs a source URL and a confidence level (see <code>src/data/guides.ts</code>).</Note>
    </>
  );
}
