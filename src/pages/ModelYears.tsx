import { modelYears } from '../data/modelYears';
import { production } from '../data/production';
import { Cite, Conflicts, Note, fmt } from '../components/Facts';
import { useT } from '../components/SettingsContext';


export default function ModelYears() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.years')}</h1>
      {(['Ford', 'Shelby American'] as const).map((b) => (
        <section key={b}>
          <h2>{b === 'Ford' ? t('years.ford') : t('years.shelby')}</h2>
          {modelYears.filter((m) => m.builder === b).map((m) => (
            <article key={m.id} className="card">
              <h3>{m.name} <Cite c={m.confidence} url={m.source} /></h3>
              <p>{m.summary}</p>
              <ul>{m.changes.map((c) => <li key={c}>{c}</li>)}</ul>
              {m.note && <Note>{m.note}</Note>}
            </article>
          ))}
        </section>
      ))}
      <section className="card">
        <h2>{t('years.production')}</h2>
        <p className="muted">{t('years.noTotals')}</p>
        <dl className="facts">
          {production.map((p) => (
            <div key={p.id} className={`fact ${p.value === null ? 'unknown' : ''}`}>
              <dt>{p.label} <span className="muted">({p.scope})</span></dt>
              <dd><span className="val">{fmt(p.value)}</span> <Cite c={p.confidence} url={p.source} />{p.conflicts && <><div className="conflict-tag">{t('common.sourcesDisagree')}</div><Conflicts values={p.conflicts} /></>}{p.note && <Note>{p.note}</Note>}</dd>
            </div>
          ))}
        </dl>
      </section>
    </>
  );
}
