import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { collections } from '../data';
import { editionGaps } from '../data/editions';
import { historyGaps } from '../data/history';
import { guides } from '../data/guides';
import { Badge, Src } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { CONFIDENCES, computeCoverage, percentages } from '../lib/coverage';

/** Data coverage dashboard: computed from src/data on every render, so it can never go stale. */
export default function Coverage() {
  const t = useT();
  const cov = useMemo(() => computeCoverage(collections), []);
  const [section, setSection] = useState('');
  const pct = percentages(cov.totals.counts);
  const gaps = section ? cov.gaps.filter((g) => g.collection === section) : cov.gaps;
  const bySection = gaps.reduce<Record<string, typeof gaps>>((a, g) => { (a[g.collection] ||= []).push(g); return a; }, {});
  const open = [
    ...editionGaps.map((g) => ({ text: g, to: '/editions' })),
    ...historyGaps.map((g) => ({ text: g, to: '/history' })),
    ...guides.filter((g) => g.status === 'planned').map((g) => ({ text: g.title, to: `/guides/${g.id}` })),
  ];
  return (
    <>
      <h1>{t('nav.coverage')}</h1>
      <p className="lede">{t('cov.lede')}</p>

      <section className="card" aria-labelledby="cov-sum">
        <h2 id="cov-sum">{t('cov.summary')}</h2>
        <div className="stats">
          <div className="stat"><div className="stat-l">{t('cov.records')}</div><div className="stat-v">{cov.totals.records}</div></div>
          <div className="stat"><div className="stat-l">{t('cov.facts')}</div><div className="stat-v">{cov.totals.facts}</div></div>
          <div className="stat"><div className="stat-l">{t('cov.gaps')}</div><div className="stat-v">{cov.totals.gaps}</div></div>
          <div className="stat"><div className="stat-l">{t('cov.conflicts')}</div><div className="stat-v">{cov.totals.conflicts}</div></div>
        </div>
        <div className="cov-bar" role="img" aria-label={t('cov.barLabel', { c: pct.confirmed, r: pct.reported, u: pct.unverified })}>
          {CONFIDENCES.map((c) => <span key={c} className={`cov-seg cov-${c}`} style={{ width: `${pct[c]}%` }} />)}
        </div>
        <ul className="legend-list">
          {CONFIDENCES.map((c) => <li key={c}><Badge c={c} /> {cov.totals.counts[c]} ({pct[c]}%)</li>)}
        </ul>
        <p className="small muted">{t('cov.howTo')} <a href="https://github.com/Catsasstrophy-Warez/LetsFNgo/blob/main/CONTRIBUTING.md" target="_blank" rel="noopener noreferrer">CONTRIBUTING.md ↗</a></p>
      </section>

      <section className="card" aria-labelledby="cov-sec">
        <h2 id="cov-sec">{t('cov.bySection')}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-labelledby="cov-sec">
          <table className="tbl">
            <thead><tr><th scope="col">{t('cov.section')}</th><th scope="col">{t('cov.records')}</th>{CONFIDENCES.map((c) => <th key={c} scope="col"><Badge c={c} /></th>)}<th scope="col">{t('cov.gaps')}</th><th scope="col">{t('cov.conflicts')}</th></tr></thead>
            <tbody>
              {cov.sections.map((s) => (
                <tr key={s.name}>
                  <th scope="row"><code>{s.name}</code></th><td>{s.records}</td>
                  {CONFIDENCES.map((c) => <td key={c}>{s.counts[c]}</td>)}
                  <td>{s.gaps}</td><td>{s.conflicts}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="card" aria-labelledby="cov-gap">
        <h2 id="cov-gap">{t('cov.gapList', { n: gaps.length })}</h2>
        <p className="muted small">{t('cov.gapText')}</p>
        <label>{t('cov.filter')}
          <select className="input" value={section} onChange={(e) => setSection(e.target.value)}>
            <option value="">{t('cov.all')}</option>
            {cov.sections.filter((s) => s.gaps).map((s) => <option key={s.name} value={s.name}>{s.name} ({s.gaps})</option>)}
          </select>
        </label>
        {Object.entries(bySection).map(([name, list]) => (
          <details key={name} className="cov-group" open={!!section}>
            <summary><code>{name}</code> — {list.length}</summary>
            <ul className="cov-list">
              {list.map((g, i) => (
                <li key={`${g.id}-${g.field}-${i}`}>
                  <Link to={g.route}>{g.label}</Link> <code className="small">{g.field}</code> <Badge c={g.confidence} />
                  <div className="small muted">{g.need ? `${t('cov.needs')} ${g.need}` : t('cov.needsDefault')}</div>
                </li>
              ))}
            </ul>
          </details>
        ))}
      </section>

      <section className="card" aria-labelledby="cov-open">
        <h2 id="cov-open">{t('cov.open', { n: open.length })}</h2>
        <ul className="cov-list">{open.map((o) => <li key={o.text}><Link to={o.to}>{o.text}</Link></li>)}</ul>
      </section>

      <section className="card" aria-labelledby="cov-cf">
        <h2 id="cov-cf">{t('cov.conflictList', { n: cov.conflicts.length })}</h2>
        <ul className="cov-list">
          {cov.conflicts.map((c) => (
            <li key={`${c.collection}-${c.id}-${c.field}`}>
              <Link to={c.route}>{c.label}</Link> <span className="small muted">({c.collection}, {c.field})</span>
              <ul className="conflicts">
                {c.values.map((v, i) => <li key={i}><strong>{v.value}</strong>{v.context && <span className="muted"> — {v.context}</span>} <Badge c={v.confidence} /> <Src url={v.source} /></li>)}
              </ul>
            </li>
          ))}
        </ul>
      </section>

      <section className="card" aria-labelledby="cov-dom">
        <h2 id="cov-dom">{t('cov.domains', { n: cov.domains.length })}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-labelledby="cov-dom">
          <table className="tbl">
            <thead><tr><th scope="col">{t('cov.domain')}</th><th scope="col">{t('cov.urls')}</th><th scope="col">{t('cov.facts')}</th>{CONFIDENCES.map((c) => <th key={c} scope="col"><Badge c={c} /></th>)}</tr></thead>
            <tbody>
              {cov.domains.map((d) => (
                <tr key={d.host}><th scope="row">{d.host}</th><td>{d.urls}</td><td>{d.facts}</td>{CONFIDENCES.map((c) => <td key={c}>{d.counts[c]}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="small"><Link to="/sources">{t('cov.allSources')}</Link></p>
      </section>
    </>
  );
}
