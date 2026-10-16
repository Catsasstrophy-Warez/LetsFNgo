import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router';
import { Badge, Cite, Note } from '../components/Facts';
import { guides } from '../data/guides';
import { partNumbers } from '../data/parts';
import { loadChecks, saveChecks } from '../lib/checklist';

export default function Guide() {
  const { id } = useParams();
  const g = guides.find((x) => x.id === id);
  const [checks, setChecks] = useState<boolean[]>(() => (g ? loadChecks(g.id, g.steps.length) : []));
  useEffect(() => { if (g) setChecks(loadChecks(g.id, g.steps.length)); }, [g]);
  if (!g) return <><h1>Guide not found</h1><p><Link to="/guides">All guides →</Link></p></>;
  const toggle = (i: number) => setChecks((c) => { const n = c.map((x, j) => (j === i ? !x : x)); saveChecks(g.id, n); return n; });
  const done = checks.filter(Boolean).length;
  const parts = partNumbers.filter((p) => g.partIds.includes(p.id));
  return (
    <>
      <p className="small"><Link to="/guides">← All guides</Link></p>
      <h1>{g.title}</h1>
      <p className="lede">{g.summary} <Badge c={g.confidence} /></p>
      <p className="muted small">Applies to: {g.appliesTo}{g.note && ` · ${g.note}`}</p>
      {g.warnings.map((w, i) => <div key={i} className="card warn" role="note"><strong>Warning:</strong> {w.text} <Cite c={w.confidence} url={w.source} /></div>)}
      {g.status === 'planned' ? <p className="muted">This guide is a planned slot: no source backs a procedure yet.</p> : (
        <section className="card">
          <h2>Steps</h2>
          <p className="muted small" role="status">{done} of {g.steps.length} done (kept for this browser session)</p>
          <ol className="guide-steps">
            {g.steps.map((s, i) => (
              <li key={i} className={checks[i] ? 'done' : ''}>
                <label className="check"><input type="checkbox" checked={!!checks[i]} onChange={() => toggle(i)} /><span>{s.text}</span></label>
                <span className="small"><Cite c={s.confidence} url={s.source} /></span>
              </li>
            ))}
          </ol>
          {done > 0 && <button className="btn ghost" onClick={() => { const n = g.steps.map(() => false); saveChecks(g.id, n); setChecks(n); }}>Clear ticks</button>}
        </section>
      )}
      <section className="card">
        <h2>Tools</h2>
        {g.tools.length ? <ul>{g.tools.map((t) => <li key={t}>{t}</li>)}</ul> : <p className="muted">No tool list is sourced for this guide yet.</p>}
      </section>
      {parts.length > 0 && (
        <section className="card">
          <h2>Parts &amp; fluids</h2>
          <ul>{parts.map((p) => <li key={p.id}><Link to={`/parts?q=${encodeURIComponent(p.number)}`} className="mono">{p.number}</Link> {p.kind === 'avoid' ? '(do not use) ' : ''}{p.description}</li>)}</ul>
        </section>
      )}
      <Note>Confidence: the guide badge is the weakest of its steps. Verify against your own owner's manual.</Note>
    </>
  );
}
