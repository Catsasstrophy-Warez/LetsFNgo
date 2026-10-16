import { packages } from '../data/packages';
import { prices, marketSales } from '../data/pricing';
import { Badge, Cite, Conflicts, Note, usd } from '../components/Facts';

export default function Packages() {
  return (
    <>
      <h1>Packages &amp; Pricing</h1>
      <section>
        <h2>Option packages</h2>
        {packages.map((p) => (
          <article key={p.id} className="card">
            <h3>{p.name} <Cite c={p.confidence} url={p.source} /></h3>
            <div className="muted">Years: {p.years.length ? p.years.join(', ') : 'Unknown'}</div>
            <div>Price: <strong>{usd(p.price.value)}</strong> {p.price.context && <span className="muted">({p.price.context})</span>} <Cite c={p.price.confidence} url={p.price.source} /></div>
            {p.priceConflicts && <><div className="conflict-tag">Other reported prices</div><Conflicts values={p.priceConflicts} money /></>}
            {p.contents.length > 0 && <>
              <div className="sub">Contents <Badge c={p.contentsConfidence} /></div>
              <ul>{p.contents.map((c) => <li key={c}>{c}</li>)}</ul>
            </>}
            {p.note && <Note>{p.note}</Note>}
          </article>
        ))}
      </section>
      <section className="card">
        <h2>MSRP by year</h2>
        <table className="tbl">
          <thead><tr><th>Year</th><th>Item</th><th>Amount</th><th>Source</th></tr></thead>
          <tbody>{prices.map((p) => (
            <tr key={p.id}><td>{p.year}</td><td>{p.label}{p.note && <Note>{p.note}</Note>}</td><td>{usd(p.value)}</td><td><Cite c={p.confidence} url={p.source} /></td></tr>
          ))}</tbody>
        </table>
      </section>
      <section className="card">
        <h2>Market results</h2>
        <p className="muted">Low-mile CFTP cars now trade near or below original sticker. No 2026-dated sales or current Hagerty values were retrieved.</p>
        <table className="tbl">
          <thead><tr><th>Car</th><th>Venue</th><th>Result</th><th>Source</th></tr></thead>
          <tbody>{marketSales.map((m) => (
            <tr key={m.id}><td>{m.year} · {m.description}</td><td>{m.venue}{m.date && ` (${m.date})`}</td><td>{usd(m.amount)} <span className="muted">{m.outcome}</span></td><td><Cite c={m.confidence} url={m.source} />{m.note && <Note>{m.note}</Note>}</td></tr>
          ))}</tbody>
        </table>
      </section>
    </>
  );
}
