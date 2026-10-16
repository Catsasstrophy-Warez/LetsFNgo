import { useState } from 'react';
import { Link } from 'react-router-dom';
import { search } from '../lib/search';
import { Src } from '../components/Facts';

export default function Search() {
  const [q, setQ] = useState('');
  const hits = search(q);
  return (
    <>
      <h1>Search</h1>
      <input className="input" type="search" autoFocus placeholder="e.g. curb weight, Code Orange, recall, Whipple" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search all data" />
      {q && <p className="muted">{hits.length} result{hits.length === 1 ? '' : 's'}</p>}
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
