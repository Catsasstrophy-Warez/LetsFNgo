import { competitors, SHEET_CAVEAT } from '../data/competitors';
import { useState } from 'react';
import { Cite, Note } from '../components/Facts';

const sheets = competitors.flatMap((c) => (c.sheet ? [c.sheet] : []));
const hiddenCount = sheets.filter((s) => s.hidden).length;

const n = (x: number | null, pre = '', post = '') => (x === null ? '—' : `${pre}${x.toLocaleString('en-US')}${post}`);

const v = (x: string | null) => x ?? <span className="muted">Not gathered</span>;

export default function Compare() {
  const [all, setAll] = useState(false);
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
      <section className="card">
        <h2>Spec-sheet comparison</h2>
        <p className="muted"><strong>Caveat:</strong> {SHEET_CAVEAT}</p>
        <label className="check"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /><span>Show {hiddenCount} hidden unverified row{hiddenCount === 1 ? '' : 's'}</span></label>
        <table className="tbl">
          <thead><tr><th>Model</th><th>hp</th><th>lb-ft</th><th>Weight</th><th>0–60</th><th>¼ mi</th><th>Price</th><th>Ref.</th></tr></thead>
          <tbody>{sheets.filter((s) => all || !s.hidden).map((s) => (
            <tr key={s.model} className={s.hidden ? 'muted' : ''}><td>{s.model}{s.note && <div className="small muted">{s.note}</div>}</td><td>{n(s.hp)}</td><td>{n(s.torque)}</td><td>{n(s.weightLb, '', ' lb')}</td>
              <td>{n(s.zeroTo60, '', ' s')}{s.zeroTo60By && <div className="small muted">{s.zeroTo60By}</div>}</td><td>{s.quarterMile ?? '—'}</td><td>{n(s.priceUsd, '$')}</td><td><Cite c={s.confidence} url={s.source} /></td></tr>
          ))}</tbody>
        </table>
      </section>
    </>
  );
}
