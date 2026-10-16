import { packages } from '../data/packages';
import { prices, marketSales } from '../data/pricing';
import { Badge, Cite, Conflicts, Note, usd } from '../components/Facts';
import { Link } from 'react-router';
import { useT } from '../components/SettingsContext';


export default function Packages() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.packages')}</h1>
      <section>
        <h2>{t('pkg.options')}</h2>
        {packages.map((p) => (
          <article key={p.id} className="card">
            <h3>{p.name} <Cite c={p.confidence} url={p.source} /></h3>
            <div className="muted">{t('colors.years')} {p.years.length ? p.years.join(', ') : t('common.unknown')}</div>
            <div>{t('pkg.price')} <strong>{usd(p.price.value)}</strong> {p.price.context && <span className="muted">({p.price.context})</span>} <Cite c={p.price.confidence} url={p.price.source} /></div>
            {p.priceConflicts && <><div className="conflict-tag">{t('pkg.otherPrices')}</div><Conflicts values={p.priceConflicts} money /></>}
            {p.contents.length > 0 && <>
              <div className="sub">{t('pkg.contents')} <Badge c={p.contentsConfidence} /></div>
              <ul>{p.contents.map((c) => <li key={c}>{c}</li>)}</ul>
            </>}
            {p.note && <Note>{p.note}</Note>}
          </article>
        ))}
      </section>
      <section className="card">
        <h2>{t('pkg.msrp')}</h2>
        <table className="tbl">
          <thead><tr><th>{t('common.year')}</th><th>{t('pkg.item')}</th><th>{t('pkg.amount')}</th><th>{t('common.source')}</th></tr></thead>
          <tbody>{prices.map((p) => (
            <tr key={p.id}><td>{p.year}</td><td>{p.label}{p.note && <Note>{p.note}</Note>}</td><td>{usd(p.value)}</td><td><Cite c={p.confidence} url={p.source} /></td></tr>
          ))}</tbody>
        </table>
      </section>
      <section className="card">
        <h2>{t('pkg.market')}</h2>
        <p className="muted">{t('pkg.marketNote')} <Link to="/market">{t('nav.market')} →</Link></p>
        <table className="tbl">
          <thead><tr><th>{t('pkg.car')}</th><th>{t('pkg.venue')}</th><th>{t('pkg.result')}</th><th>{t('common.source')}</th></tr></thead>
          <tbody>{marketSales.map((m) => (
            <tr key={m.id}><td>{m.year} · {m.description}</td><td>{m.venue}{m.date && ` (${m.date})`}</td><td>{usd(m.amount)} <span className="muted">{t(`pkg.outcome.${m.outcome}`)}</span></td><td><Cite c={m.confidence} url={m.source} />{m.note && <Note>{m.note}</Note>}</td></tr>
          ))}</tbody>
        </table>
      </section>
    </>
  );
}
