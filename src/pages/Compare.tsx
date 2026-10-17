import { competitors, SHEET_CAVEAT } from '../data/competitors';
import { useState } from 'react';
import { Cite, Note } from '../components/Facts';
import { tr } from '../lib/i18n';
import { useT } from '../components/SettingsContext';


const sheets = competitors.flatMap((c) => (c.sheet ? [c.sheet] : []));
const hiddenCount = sheets.filter((s) => s.hidden).length;

const n = (x: number | null, pre = '', post = '') => (x === null ? '—' : `${pre}${x.toLocaleString('en-US')}${post}`);

const v = (x: string | null) => x ?? <span className="muted">{tr('cmp.notGathered')}</span>;

export default function Compare() {
  const t = useT();
  const [all, setAll] = useState(false);
  return (
    <>
      <h1>{t('nav.compare')}</h1>
      <p className="lede">{t('cmp.lede')}</p>
      <h2>{t('cmp.tested')}</h2>
      <div className="compare">
        {competitors.map((c) => (
          <article key={c.id} className={`card ${c.id === 'gt500' ? 'hl' : ''}`}>
            <h3>{c.name}</h3>
            <dl className="facts compact">
              <div className="fact"><dt>{t('cmp.power')}</dt><dd>{v(c.power)}</dd></div>
              <div className="fact"><dt>{t('cmp.quarter')}</dt><dd>{v(c.quarterMile)}</dd></div>
              <div className="fact"><dt>{t('cmp.lap')}</dt><dd>{v(c.lap)}</dd></div>
              <div className="fact"><dt>{t('cmp.price')}</dt><dd>{v(c.price)}</dd></div>
            </dl>
            <p>{c.verdict}</p>
            <Cite c={c.confidence} url={c.source} />
            {c.note && <Note>{c.note}</Note>}
          </article>
        ))}
      </div>
      <section className="card">
        <h2>{t('cmp.sheet')}</h2>
        <p className="muted"><strong>{t('cmp.caveat')}</strong> {SHEET_CAVEAT}</p>
        <label className="check"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /><span>{t('cmp.showHidden', { n: hiddenCount })}</span></label>
        <table className="tbl">
          <thead><tr><th>{t('cmp.model')}</th><th>hp</th><th>lb-ft</th><th>{t('cmp.weight')}</th><th>0–60</th><th>¼ mi</th><th>{t('cmp.price')}</th><th>{t('cmp.ref')}</th></tr></thead>
          <tbody>{sheets.filter((s) => all || !s.hidden).map((s) => (
            <tr key={s.model} className={s.hidden ? 'muted' : ''}><td>{s.model}{s.note && <div className="small muted">{s.note}</div>}</td><td>{n(s.hp)}</td><td>{n(s.torque)}</td><td>{n(s.weightLb, '', ' lb')}</td>
              <td>{n(s.zeroTo60, '', ' s')}{s.zeroTo60By && <div className="small muted">{s.zeroTo60By}</div>}</td><td>{s.quarterMile ?? '—'}</td><td>{s.msrp ? <>{n(s.msrp.value, '$')}<div className="small muted">MY{s.msrp.modelYear}{s.msrp.destinationIncluded === true ? ` · ${t('cmp.inclDest')}` : s.msrp.destinationIncluded === false ? ` · ${t('cmp.exclDest')}` : ''}</div><Cite c={s.msrp.confidence} url={s.msrp.source} />{s.msrp.conflicts?.map((c, i) => <div key={i} className="small muted">{t('cmp.alsoReported')} {n(c.value, '$')} <Cite c={c.confidence} url={c.source} /></div>)}</> : n(s.priceUsd, '$')}</td><td><Cite c={s.confidence} url={s.source} /></td></tr>
          ))}</tbody>
        </table>
      </section>
    </>
  );
}
