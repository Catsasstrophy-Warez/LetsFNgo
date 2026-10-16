import { useState } from 'react';
import { CarArt } from '../components/CarArt';
import { Cite, Note, fmt } from '../components/Facts';
import { paintInfo, paintsFor, stripeFor } from '../lib/paint';

export default function Visualizer() {
  const [year, setYear] = useState<2020 | 2021 | 2022 | 'all'>('all');
  const [stripes, setStripes] = useState(true);
  const list = paintsFor(year);
  const [sel, setSel] = useState(list[0].id);
  const info = paintInfo(list.some((c) => c.id === sel) ? sel : list[0].id)!;
  const c = info.color;
  return (
    <>
      <h1>Color Visualizer</h1>
      <p className="lede">The generic silhouette in each documented paint color. Swatches are approximate screen colors, not official values; stripes are illustrative.</p>
      <div className="seg" role="tablist" aria-label="Model year">
        {(['all', 2020, 2021, 2022] as const).map((y) => (
          <button key={y} role="tab" aria-selected={year === y} className={year === y ? 'on' : ''} onClick={() => setYear(y)}>{y === 'all' ? 'All years' : y}</button>
        ))}
      </div>
      <section className="card viz">
        <CarArt body={c.swatch} stripe={stripeFor(c.swatch)} stripes={stripes} label={`Fastback illustration in ${c.name}${stripes ? ' with stripes' : ''}`} />
        <label className="check"><input type="checkbox" checked={stripes} onChange={(e) => setStripes(e.target.checked)} /><span>Show racing stripes</span></label>
        <div aria-live="polite">
          <h2>{c.name}</h2>
          <dl className="facts">
            <div className="fact"><dt>Paint code</dt><dd className="val">{c.code ?? 'Unknown'}</dd></div>
            <div className="fact"><dt>Documented years</dt><dd>{c.years.join(', ')}{c.yearsNote && <Note>{c.yearsNote}</Note>}</dd></div>
            <div className="fact"><dt>Production count</dt><dd>
              {info.count ? <><span className="val">{fmt(info.count.value)}</span> ({info.count.scope}) <Cite c={info.count.confidence} url={info.count.source} />{info.count.note && <Note>{info.count.note}</Note>}</> : <span className="muted">Not sourced</span>}
            </dd></div>
            <div className="fact"><dt>Rarity rank</dt><dd>{info.rank ? <><span className="val">#{info.rank} rarest</span> of {info.rankOf} 2020 colors with a count</> : <span className="muted">Unknown — no sourced count</span>}</dd></div>
            <div className="fact"><dt>Source</dt><dd><Cite c={c.confidence} url={c.source} />{c.note && <Note>{c.note}</Note>}</dd></div>
          </dl>
        </div>
      </section>
      <div className="swatch-picker" role="radiogroup" aria-label="Paint color">
        {list.map((p) => (
          <button key={p.id} role="radio" aria-checked={p.id === c.id} className={`swatch-btn ${p.id === c.id ? 'on' : ''}`} onClick={() => setSel(p.id)}>
            <span className="dot big" style={{ background: p.swatch }} aria-hidden />
            <span>{p.name}</span>
          </button>
        ))}
      </div>
      <Note>Counts are 2020 forum/dealer tallies (unverified); Ford does not publish color splits. Rarity ranks only compare colors that have a count.</Note>
    </>
  );
}
