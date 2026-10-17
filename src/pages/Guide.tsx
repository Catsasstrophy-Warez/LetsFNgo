import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router';
import { Badge, Cite, Note } from '../components/Facts';
import { guides } from '../data/guides';
import { partNumbers } from '../data/parts';
import { loadChecks, saveChecks } from '../lib/checklist';
import { useT } from '../components/SettingsContext';


export default function Guide() {
  const { id } = useParams();
  const t = useT();
  const g = guides.find((x) => x.id === id);
  const [checks, setChecks] = useState<boolean[]>(() => (g ? loadChecks(g.id, g.steps.length) : []));
  useEffect(() => { if (g) setChecks(loadChecks(g.id, g.steps.length)); }, [g]);
  if (!g) return <><h1>{t('guide.notFound')}</h1><p><Link to="/guides">{t('guide.all')}</Link></p></>;
  const toggle = (i: number) => setChecks((c) => { const n = c.map((x, j) => (j === i ? !x : x)); saveChecks(g.id, n); return n; });
  const done = checks.filter(Boolean).length;
  const parts = partNumbers.filter((p) => g.partIds.includes(p.id));
  return (
    <>
      <p className="small"><Link to="/guides">{t('guide.back')}</Link></p>
      <h1>{g.title}</h1>
      <p className="lede">{g.summary} <Badge c={g.confidence} /></p>
      <p className="muted small">{t('guide.applies', { a: g.appliesTo })}{g.note && ` · ${g.note}`}</p>
      {g.warnings.map((w, i) => <div key={i} className="card warn" role="note"><strong>{t('guide.warning')}</strong> {w.text} <Cite c={w.confidence} url={w.source} /></div>)}
      {g.status === 'planned' ? <p className="muted">{t('guide.plannedSlot')}</p> : (
        <section className="card">
          <h2>{t('guide.steps')}</h2>
          <p className="muted small" role="status">{t('guide.done', { d: done, n: g.steps.length })}</p>
          <ol className="guide-steps">
            {g.steps.map((s, i) => (
              <li key={i} className={checks[i] ? 'done' : ''}>
                <label className="check"><input type="checkbox" checked={!!checks[i]} onChange={() => toggle(i)} /><span>{s.text}</span></label>
                <span className="small"><Cite c={s.confidence} url={s.source} /></span>
              </li>
            ))}
          </ol>
          {done > 0 && <button className="btn ghost" onClick={() => { const n = g.steps.map(() => false); saveChecks(g.id, n); setChecks(n); }}>{t('guide.clear')}</button>}
        </section>
      )}
      <section className="card">
        <h2>{t('guide.tools')}</h2>
        {g.tools.length ? <ul>{g.tools.map((x) => <li key={x}>{x}</li>)}</ul> : <p className="muted">{t('guide.noTools')}</p>}
      </section>
      {parts.length > 0 && (
        <section className="card">
          <h2>{t('guide.parts')}</h2>
          <ul>{parts.map((p) => <li key={p.id}><Link to={`/parts?q=${encodeURIComponent(p.number)}`} className="mono">{p.number}</Link> {p.kind === 'avoid' ? t('guide.avoid') : ''}{p.description}</li>)}</ul>
        </section>
      )}
      <Note>{t('guide.note')}</Note>
    </>
  );
}
