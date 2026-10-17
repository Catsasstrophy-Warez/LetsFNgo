import { Link } from 'react-router';
import { Badge, Note } from '../components/Facts';
import { guides } from '../data/guides';
import { useT } from '../components/SettingsContext';


export default function Guides() {
  const t = useT();
  const ready = guides.filter((g) => g.status === 'ready');
  const planned = guides.filter((g) => g.status === 'planned');
  return (
    <>
      <h1>{t('nav.guides')}</h1>
      <p className="lede">{t('guides.lede')}</p>
      <ul className="rows">
        {ready.map((g) => (
          <li key={g.id}>
            <div className="row-main"><Link to={`/guides/${g.id}`}><strong>{g.title}</strong></Link> <Badge c={g.confidence} /></div>
            <p className="muted small">{g.summary} · {t('guides.steps', { n: g.steps.length })} · {g.appliesTo}</p>
          </li>
        ))}
      </ul>
      <section className="card">
        <h2>{t('guides.planned')}</h2>
        <ul className="rows">
          {planned.map((g) => <li key={g.id}><strong>{g.title}</strong><p className="muted small">{g.summary}</p></li>)}
        </ul>
      </section>
      <Note>{t('guides.add')} <code>src/data/guides.ts</code>).</Note>
    </>
  );
}
