import { competitors } from '../data/competitors';
import { Cite, Note } from '../components/Facts';

const v = (x: string | null) => x ?? <span className="muted">Not gathered</span>;

export default function Compare() {
  return (
    <>
      <h1>Compare</h1>
      <p className="lede">Rivals split by venue: the GT500 won at the drag strip; the Camaro ZL1 1LE matched it on road courses for less money.</p>
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
    </>
  );
}
