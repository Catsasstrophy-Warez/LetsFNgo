import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { partSlots } from '../data/parts';
import { maintenance } from '../data/maintenance';
import { copyText, filterParts } from '../lib/parts';

export default function Parts() {
  const [params, setParams] = useSearchParams();
  const q = params.get('q') ?? '';
  const [copied, setCopied] = useState<{ id: string; ok: boolean } | null>(null);
  const list = filterParts(q);
  const copy = async (id: string, number: string) => setCopied({ id, ok: await copyText(number) });
  return (
    <>
      <h1>Parts &amp; Fluids</h1>
      <p className="lede">Part numbers and Ford fluid specs that a cited source names, each with its confidence. Copy a number to take to the parts counter. Empty slots stay empty until a source is found. <Link to="/garage#maintenance">Maintenance reminders →</Link></p>
      <div className="form">
        <label>Search parts<input className="input" type="search" value={q} placeholder="e.g. FL-2087, coolant, spark" onChange={(e) => setParams(e.target.value ? { q: e.target.value } : {}, { replace: true })} /></label>
      </div>
      <p className="muted small" role="status">{list.length} of the catalog's entries match.</p>
      <ul className="rows parts-list">
        {list.map((p) => {
          const facts = maintenance.filter((m) => p.maintenanceIds.includes(m.id));
          return (
            <li key={p.id} id={p.id} className={p.kind === 'avoid' ? 'avoid' : ''}>
              <div className="row-main">
                <span><strong className="mono part-no">{p.number}</strong> <span className="muted">{p.brand} · {p.category}</span></span>
                <button className="btn ghost small-btn" onClick={() => copy(p.id, p.number)} aria-label={`Copy ${p.number}`}>{copied?.id === p.id ? (copied.ok ? 'Copied' : 'Copy failed') : 'Copy'}</button>
              </div>
              <p>{p.kind === 'avoid' && <strong className="err">Do not use: </strong>}{p.description}</p>
              <p className="small"><Cite c={p.confidence} url={p.source} />{p.note && <span className="muted"> {p.note}</span>}</p>
              {facts.length > 0 && <p className="small muted">Related: {facts.map((f, i) => <span key={f.id}>{i ? ', ' : ''}<Link to="/ownership">{f.item}</Link></span>)}</p>}
            </li>
          );
        })}
      </ul>
      {list.length === 0 && <p className="muted">No part matches “{q}”.</p>}
      <section className="card">
        <h2>Not sourced yet</h2>
        <p className="muted">No source names a part number for these yet, so the app leaves them blank:</p>
        <ul>{partSlots.map((s) => <li key={s}>{s}</li>)}</ul>
      </section>
      <Note>Part numbers can be superseded. Check the number against your VIN at a Ford parts counter before you order.</Note>
    </>
  );
}
