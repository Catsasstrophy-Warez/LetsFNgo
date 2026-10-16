import { useState } from 'react';
import { Link } from 'react-router';
import { search } from '../lib/search';
import { Src } from '../components/Facts';
import { useT } from '../components/SettingsContext';

export default function Search() {
  const t = useT();
  const [q, setQ] = useState('');
  const hits = search(q);
  return (
    <>
      <h1>{t('nav.search')}</h1>
      <input id="search-input" className="input" type="search" autoFocus placeholder={t('search.placeholder')} value={q} onChange={(e) => setQ(e.target.value)} aria-label={t('search.label')} />
      {q && <p className="muted">{t('search.count', { n: hits.length })}</p>}
      <ul className="rows">
        {hits.map((h, i) => (
          <li key={i}>
            <div className="row-main"><Link to={h.route}><strong>{h.title}</strong></Link><span className="tag">{h.collection}</span></div>
            <p className="muted clamp">{h.text}</p>
            {h.collection !== 'tools' && <Src url={h.source} />}
          </li>
        ))}
      </ul>
    </>
  );
}
