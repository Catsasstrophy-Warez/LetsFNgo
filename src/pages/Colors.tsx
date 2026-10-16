import { useState } from 'react';
import { colors } from '../data/colors';
import type { ModelYear } from '../data/types';
import { Cite, Note } from '../components/Facts';

export default function Colors() {
  const [year, setYear] = useState<ModelYear | 'all'>('all');
  const list = colors.filter((c) => year === 'all' || c.years.includes(year));
  return (
    <>
      <h1>Colors</h1>
      <p className="lede">Colors documented in sources. The complete per-year list with paint codes was not retrieved, so codes show “Unknown” unless sourced. Swatches are approximate.</p>
      <div className="seg" role="tablist">
        {(['all', 2020, 2021, 2022] as const).map((y) => (
          <button key={y} role="tab" aria-selected={year === y} className={year === y ? 'on' : ''} onClick={() => setYear(y)}>{y === 'all' ? 'All' : y}</button>
        ))}
      </div>
      <div className="swatches">
        {list.map((c) => (
          <article key={c.id} className="card swatch-card">
            <div className="swatch" style={{ background: c.swatch }} aria-hidden />
            <h3>{c.name}</h3>
            <div>Code: <strong>{c.code ?? 'Unknown'}</strong></div>
            <div>Years: {c.years.join(', ')}</div>
            <Cite c={c.confidence} url={c.source} />
            {c.yearsNote && <Note>{c.yearsNote}</Note>}
            {c.note && <Note>{c.note}</Note>}
          </article>
        ))}
      </div>
    </>
  );
}
