import { useState } from 'react';
import { CarArt } from '../components/CarArt';
import { Cite, Note, fmt } from '../components/Facts';
import { paintInfo, paintsFor, stripeFor } from '../lib/paint';
import { useT } from '../components/SettingsContext';


export default function Visualizer() {
  const t = useT();
  const [year, setYear] = useState<2020 | 2021 | 2022 | 'all'>('all');
  const [stripes, setStripes] = useState(true);
  const list = paintsFor(year);
  const [sel, setSel] = useState(list[0].id);
  const info = paintInfo(list.some((c) => c.id === sel) ? sel : list[0].id)!;
  const c = info.color;
  return (
    <>
      <h1>{t('nav.visualizer')}</h1>
      <p className="lede">{t('viz.lede')}</p>
      <div className="seg" role="tablist" aria-label={t('viz.year')}>
        {(['all', 2020, 2021, 2022] as const).map((y) => (
          <button key={y} role="tab" aria-selected={year === y} className={year === y ? 'on' : ''} onClick={() => setYear(y)}>{y === 'all' ? t('common.allYears') : y}</button>
        ))}
      </div>
      <section className="card viz">
        <CarArt body={c.swatch} stripe={stripeFor(c.swatch)} stripes={stripes} label={t(stripes ? 'viz.altStripes' : 'viz.alt', { c: c.name })} />
        <label className="check"><input type="checkbox" checked={stripes} onChange={(e) => setStripes(e.target.checked)} /><span>{t('viz.stripes')}</span></label>
        <div aria-live="polite">
          <h2>{c.name}</h2>
          <dl className="facts">
            <div className="fact"><dt>{t('viz.code')}</dt><dd className="val">{c.code ?? t('common.unknown')}</dd></div>
            <div className="fact"><dt>{t('viz.years')}</dt><dd>{c.years.join(', ')}{c.yearsNote && <Note>{c.yearsNote}</Note>}</dd></div>
            <div className="fact"><dt>{t('viz.count')}</dt><dd>
              {info.count ? <><span className="val">{fmt(info.count.value)}</span> ({info.count.scope}) <Cite c={info.count.confidence} url={info.count.source} />{info.count.note && <Note>{info.count.note}</Note>}</> : <span className="muted">{t('viz.notSourced')}</span>}
            </dd></div>
            <div className="fact"><dt>{t('viz.rank')}</dt><dd>{info.rank ? <span className="val">{t('viz.rankText', { rank: info.rank, of: info.rankOf ?? '' })}</span> : <span className="muted">{t('viz.rankUnknown')}</span>}</dd></div>
            <div className="fact"><dt>{t('common.source')}</dt><dd><Cite c={c.confidence} url={c.source} />{c.note && <Note>{c.note}</Note>}</dd></div>
          </dl>
        </div>
      </section>
      <div className="swatch-picker" role="radiogroup" aria-label={t('viz.paint')}>
        {list.map((p) => (
          <button key={p.id} role="radio" aria-checked={p.id === c.id} className={`swatch-btn ${p.id === c.id ? 'on' : ''}`} onClick={() => setSel(p.id)}>
            <span className="dot big" style={{ background: p.swatch }} aria-hidden />
            <span>{p.name}</span>
          </button>
        ))}
      </div>
      <Note>{t('viz.note')}</Note>
    </>
  );
}
