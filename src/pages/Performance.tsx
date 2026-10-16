import { performance, performanceWarning } from '../data/performance';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';


const CATS = ['acceleration', 'quarter-mile', 'lap', 'drag-record'] as const;

export default function Performance() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.performance')}</h1>
      <div className="card warn">{performanceWarning.text} <Cite c={performanceWarning.confidence} url={performanceWarning.source} /></div>
      {CATS.map((k) => (
        <section key={k} className="card">
          <h2>{t(`perf.cat.${k}`)}</h2>
          <ul className="rows">
            {performance.filter((p) => p.category === k).map((p) => (
              <li key={p.id}>
                <div className="row-main"><span>{p.label}</span><strong>{p.result}</strong></div>
                <div className="row-meta"><span className={`tag ${p.car === 'modified' ? 'tag-mod' : ''}`}>{p.car}</span> <span className="muted">{p.date ?? t('common.dateUnknown')}</span> <Cite c={p.confidence} url={p.source} /></div>
                {p.note && <Note>{p.note}</Note>}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}
