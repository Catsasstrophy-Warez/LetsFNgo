import { useState } from 'react';
import { colors } from '../data/colors';
import type { ModelYear } from '../data/types';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';


export default function Colors() {
  const t = useT();
  const [year, setYear] = useState<ModelYear | 'all'>('all');
  const list = colors.filter((c) => year === 'all' || c.years.includes(year));
  return (
    <>
      <h1>{t('nav.colors')}</h1>
      <p className="lede">{t('colors.lede')}</p>
      <div className="seg" role="tablist">
        {(['all', 2020, 2021, 2022] as const).map((y) => (
          <button key={y} role="tab" aria-selected={year === y} className={year === y ? 'on' : ''} onClick={() => setYear(y)}>{y === 'all' ? t('common.all') : y}</button>
        ))}
      </div>
      <div className="swatches">
        {list.map((c) => (
          <article key={c.id} className="card swatch-card">
            <div className="swatch" style={{ background: c.swatch }} aria-hidden />
            <h3>{c.name}</h3>
            <div>{t('colors.code')} <strong>{c.code ?? t('common.unknown')}</strong></div>
            <div>{t('colors.years')} {c.years.join(', ')}</div>
            <Cite c={c.confidence} url={c.source} />
            {c.yearsNote && <Note>{c.yearsNote}</Note>}
            {c.note && <Note>{c.note}</Note>}
          </article>
        ))}
      </div>
    </>
  );
}
