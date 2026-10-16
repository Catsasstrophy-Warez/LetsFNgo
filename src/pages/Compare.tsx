import { competitors, SHEET_CAVEAT } from '../data/competitors';
import { Badge, Cite, Note } from '../components/Facts';

const n = (x: number | null, pre = '', post = '') => (x === null ? '—' : `${pre}${x.toLocaleString('en-US')}${post}`);

const v = (x: string | null) => x ?? <span className="muted">Not gathered</span>;

export default function Compare() {
  return (
    <>
      <h1>Compare</h1>
      <p className="lede">Rivals split by venue: the GT500 won at the drag strip; the Camaro ZL1 1LE matched it on road courses for less money.</p>
      <h2>Tested results</h2>
      <div className="compare">
        {competitors.map((c) => (
          <article key={c.id} className={`card ${c.id === 'gt500' ? 'hl' : ''}`}>
            <h3>{c.name}</h3>
            <dl className="facts compact">
              <div className="fact"><dt>Power</dt><dd>{v(c.power)}</dd></div>
              <div className="fact"><dt>¼ mile</dt><dd>{v(c.quarterMile)}</dd></div>
              <div className="fact"><dt>Lap</dt><dd>{v(c.lap)}</dd></div>
              <div className="fact"><dt>Price</dt><dd>{v(c.price)}</dd></div>
            </dl>
            <p>{c.verdict}</p>
            <Cite c={c.confidence} url={c.source} />
            {c.note && <Note>{c.note}</Note>}
          </article>
        ))}
      </div>
      <section className="card warn">
        <h2>Spec-sheet comparison <Badge c="unverified" /></h2>
        <p><strong>Caveat:</strong> {SHEET_CAVEAT}</p>
        <table className="tbl">
          <thead><tr><th>Car</th><th>hp</th><th>lb-ft</th><th>Weight</th><th>0–60</th><th>¼ mi</th><th>Price</th><th>Ref.</th></tr></thead>
          <tbody>{competitors.filter((c) => c.sheet).map((c) => { const s = c.sheet!; return (
            <tr key={c.id}><td>{c.name}</td><td>{n(s.hp)}</td><td>{n(s.torque)}</td><td>{n(s.weightLb, '', ' lb')}</td><td>{n(s.zeroTo60, '', ' s')}</td><td>{n(s.quarterMile, '', ' s')}</td><td>{n(s.priceUsd, '$')}</td><td><Cite c={s.confidence} url={s.source} /></td></tr>
          ); })}</tbody>
        </table>
      </section>
    </>
  );
}
