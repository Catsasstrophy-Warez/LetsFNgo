import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router';
import { clearRecent, groupHits, loadRecent, pushRecent, rankedSearch } from '../lib/search';
import { Src } from '../components/Facts';
import { useT } from '../components/SettingsContext';

/**
 * Fuzzy ranked search over every sourced record and app tool, grouped by section. Arrow keys move from the box
 * through the results (Home/End jump, Escape returns to the box); Enter on a result opens it. Recent searches
 * stay on this device.
 */
export default function Search() {
  const t = useT();
  const nav = useNavigate();
  const [q, setQ] = useState('');
  const [recent, setRecent] = useState<string[]>(loadRecent);
  const [active, setActive] = useState(-1);
  const box = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const hits = useMemo(() => rankedSearch(q), [q]);
  const groups = useMemo(() => groupHits(hits), [hits]);
  const flat = groups.flatMap((g) => g.hits);
  useEffect(() => setActive(-1), [q]);

  // Remember a query once the user pauses typing on it with results.
  useEffect(() => {
    if (q.trim().length < 2 || !hits.length) return;
    const id = setTimeout(() => setRecent(pushRecent(q)), 1500);
    return () => clearTimeout(id);
  }, [q, hits.length]);

  const focusHit = (i: number) => {
    const links = list.current?.querySelectorAll<HTMLAnchorElement>('a.hit-link');
    if (!links || !links.length) return;
    const k = Math.max(0, Math.min(links.length - 1, i));
    setActive(k); links[k].focus();
  };
  const onKey = (e: React.KeyboardEvent) => {
    const inBox = e.target === box.current;
    if (e.key === 'ArrowDown') { e.preventDefault(); focusHit(inBox ? 0 : active + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (active <= 0) { setActive(-1); box.current?.focus(); } else focusHit(active - 1); }
    else if (!inBox && e.key === 'Home') { e.preventDefault(); focusHit(0); }
    else if (!inBox && e.key === 'End') { e.preventDefault(); focusHit(flat.length - 1); }
    else if (e.key === 'Escape' && !inBox) { setActive(-1); box.current?.focus(); }
    else if (e.key === 'Enter' && inBox && flat[0]) { setRecent(pushRecent(q)); nav(flat[0].route); }
  };

  let n = -1;
  return (
    <div onKeyDown={onKey}>
      <h1>{t('nav.search')}</h1>
      <input ref={box} id="search-input" className="input" type="search" autoFocus placeholder={t('search.placeholder')} value={q} onChange={(e) => setQ(e.target.value)} aria-label={t('search.label')} aria-describedby="search-help" />
      <p id="search-help" className="muted small">{t('search.help')}</p>
      {!q && recent.length > 0 && (
        <section aria-labelledby="recent-h">
          <h2 id="recent-h" className="search-group">{t('search.recent')}</h2>
          <ul className="recent">{recent.map((r) => <li key={r}><button className="chip" onClick={() => { setQ(r); box.current?.focus(); }}>{r}</button></li>)}</ul>
          <button className="link-btn small" onClick={() => { clearRecent(); setRecent([]); }}>{t('search.clearRecent')}</button>
        </section>
      )}
      {q && <p className="muted" role="status">{t('search.count', { n: hits.length })}{hits.length ? ` · ${t('search.groups', { n: groups.length })}` : ''}</p>}
      <div ref={list}>
        {groups.map((g) => (
          <section key={g.collection} aria-label={g.collection}>
            <h2 className="search-group">{g.collection === 'tools' ? t('search.tools') : g.collection} <span className="muted">({g.hits.length})</span></h2>
            <ul className="rows">
              {g.hits.map((h) => { n++; const i = n; return (
                <li key={`${h.collection}-${i}`} className={i === active ? 'active-hit' : undefined}>
                  <div className="row-main"><Link className="hit-link" to={h.route} onFocus={() => setActive(i)} onClick={() => setRecent(pushRecent(q))}><strong>{h.title}</strong></Link></div>
                  <p className="muted clamp">{h.text}</p>
                  {h.collection !== 'tools' && <Src url={h.source} />}
                </li>); })}
            </ul>
          </section>
        ))}
      </div>
    </div>
  );
}
