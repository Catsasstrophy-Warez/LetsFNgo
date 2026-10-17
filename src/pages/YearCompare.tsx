import { useState } from 'react';
import { Cite, Note, usd } from '../components/Facts';
import { YEARS, colorRows, headToHead, packageRows, priceGrid, rivals, yearCounts } from '../lib/yearDiff';
import { SHEET_CAVEAT } from '../data/competitors';
import { useT } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';


function Yes({ on, year }: { on: boolean; year: number }) {
  const t = useT();
  return on ? <span className="yes" aria-label={t('yc.listed', { y: year })}>●</span> : <span className="no muted" aria-label={t('yc.notListed', { y: year })}>–</span>;
}

export default function YearCompare() {
  const t = useT();
  const rowLabel = (l: string) => { const k = `yc.row.${l}` as MsgKey; const s = t(k); return s === k ? l : s; };
  const [onlyDiff, setOnlyDiff] = useState(true);
  const [rivalId, setRivalId] = useState(rivals()[0]?.id ?? '');
  const [hidden, setHidden] = useState(false);
  const cols = colorRows().filter((r) => !onlyDiff || r.differs);
  const pkgs = packageRows().filter((r) => !onlyDiff || r.differs);
  const h2h = headToHead(rivalId, hidden);
  return (
    <>
      <h1>{t('nav.diff')}</h1>
      <p className="lede">{t('yc.lede')}</p>
      <div className="stats">
        {yearCounts().map((y) => <div className="stat" key={y.year}><div className="stat-v">{y.year}</div><div className="stat-l">{t('yc.counts', { c: y.colors, p: y.packages })}</div></div>)}
      </div>
      <label className="check"><input type="checkbox" checked={onlyDiff} onChange={(e) => setOnlyDiff(e.target.checked)} /><span>{t('yc.onlyDiff')}</span></label>
      <section className="card">
        <h2>{t('yc.colors')}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('yc.colorsTbl')}>
          <table className="tbl diff stack">
            <thead><tr><th scope="col">{t('yc.color')}</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}<th scope="col">{t('cmp.ref')}</th></tr></thead>
            <tbody>{cols.map(({ item: c, years }) => (
              <tr key={c.id}><th scope="row"><span className="dot" style={{ background: c.swatch }} aria-hidden /> {c.name}{c.code && <span className="muted small"> {c.code}</span>}{c.yearsNote && <div className="small muted">{c.yearsNote}</div>}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}><Yes on={years[y]} year={y} /></td>)}<td data-label={t('cmp.ref')}><Cite c={c.confidence} url={c.source} /></td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
      <section className="card">
        <h2>{t('yc.pkgs')}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('yc.pkgsTbl')}>
          <table className="tbl diff stack">
            <thead><tr><th scope="col">{t('yc.pkg')}</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}<th scope="col">{t('cmp.price')}</th><th scope="col">{t('cmp.ref')}</th></tr></thead>
            <tbody>{pkgs.map(({ item: p, years }) => (
              <tr key={p.id}><th scope="row">{p.name}{p.note && <div className="small muted">{p.note}</div>}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}><Yes on={years[y]} year={y} /></td>)}<td data-label={t('cmp.price')}>{usd(p.price.value)}</td><td data-label={t('cmp.ref')}><Cite c={p.confidence} url={p.source} /></td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
      <section className="card">
        <h2>{t('yc.prices')}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('yc.pricesTbl')}>
          <table className="tbl diff stack">
            <thead><tr><th scope="col">{t('pkg.item')}</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}</tr></thead>
            <tbody>{priceGrid().map((r) => (
              <tr key={r.kind}><th scope="row">{t(`yc.kind.${r.kind}`)}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}>{r.cells[y].length ? r.cells[y].map((p) => <div key={p.id}><strong>{usd(p.value)}</strong> <span className="small muted">{p.label}</span> <Cite c={p.confidence} url={p.source} /></div>) : <span className="muted">{t('viz.notSourced')}</span>}</td>)}</tr>
            ))}</tbody>
          </table>
        </div>
        <Note>{t('yc.conflicts')}</Note>
      </section>
      <section className="card">
        <h2>{t('yc.h2h')}</h2>
        <label className="form-label">{t('yc.rival')}
          <select className="input" value={rivalId} onChange={(e) => setRivalId(e.target.value)}>
            {rivals(true).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="check"><input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} /><span>{t('yc.hidden')}</span></label>
        {h2h && (
          <>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('yc.h2hTbl')}>
              <table className="tbl h2h">
                <thead><tr><th scope="col">{t('tires.figure')}</th><th scope="col">GT500</th><th scope="col">{h2h.rival.name}</th></tr></thead>
                <tbody>{h2h.rows.filter((r) => r.gt500 !== null || r.rival !== null).map((r) => (
                  <tr key={r.label}><th scope="row">{rowLabel(r.label)}</th>
                    <td className={r.better === 'gt500' ? 'win' : ''}>{r.gt500 ?? <span className="muted">{t('viz.notSourced')}</span>}{r.better === 'gt500' && <span className="sr-only">{t('yc.better')}</span>}</td>
                    <td className={r.better === 'rival' ? 'win' : ''}>{r.rival ?? <span className="muted">{t('viz.notSourced')}</span>}{r.better === 'rival' && <span className="sr-only">{t('yc.better')}</span>}</td></tr>
                ))}</tbody>
              </table>
            </div>
            <p className="small">{t('yc.specRows')} GT500 {h2h.gtSheet ? <Cite c={h2h.gtSheet.confidence} url={h2h.gtSheet.source} /> : '—'} · {h2h.rival.name} {h2h.rivalSheet ? <Cite c={h2h.rivalSheet.confidence} url={h2h.rivalSheet.source} /> : <span className="muted">{t('yc.noSheet')}{h2h.rival.sheet?.hidden ? t('yc.hiddenTag') : ''}</span>}</p>
            <p className="small">{t('yc.testRows')} GT500 <Cite c={h2h.gt500.confidence} url={h2h.gt500.source} /> · {h2h.rival.name} <Cite c={h2h.rival.confidence} url={h2h.rival.source} /></p>
            <p>{h2h.rival.verdict}</p>
            <Note>{SHEET_CAVEAT} {t('yc.hl')}</Note>
          </>
        )}
      </section>
    </>
  );
}
