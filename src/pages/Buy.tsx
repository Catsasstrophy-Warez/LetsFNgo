import { useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { NHTSA_LOOKUP } from '../data/recalls';
import { VPIC_URL } from '../data/vin';
import type { ModelYear } from '../data/types';
import type { MsgKey } from '../lib/i18n';
import { decodeVin, normalizeVin } from '../lib/vin';
import { parseMoney, usdWhole } from '../lib/format';
import { BUY_SECTIONS, buildChecklist, positionPrice, recallsFor, type BuyItem } from '../lib/buyerGuide';
import { loadBuyer, saveBuyer, toggleCheck, type BuyerState } from '../lib/buyer';

const YEARS: ModelYear[] = [2020, 2021, 2022];

/** Buyer's guide for a used 2020–22 GT500: VIN quick-check, price positioning and a sourced inspection checklist. */
export default function Buy() {
  const t = useT();
  const [vin, setVin] = useState('');
  const [year, setYear] = useState<ModelYear | null>(null);
  const [checks, setChecks] = useState<BuyerState>(loadBuyer);
  const [saveErr, setSaveErr] = useState(false);
  const [price, setPrice] = useState({ asking: '', year: '' as '' | `${ModelYear}`, miles: '' });

  const v = normalizeVin(vin).length === 17 ? decodeVin(vin) : null;
  const vinRecalls = v?.valid && v.year ? recallsFor(v.year) : [];
  const items = buildChecklist(year);
  const done = items.filter((i) => checks.checked.includes(i.id)).length;
  const commit = (next: BuyerState) => { setChecks(next); setSaveErr(!saveBuyer(next)); };

  const asking = parseMoney(price.asking);
  const miles = price.miles.trim() === '' ? null : parseMoney(price.miles);
  const pos = asking !== null && asking > 0 && price.year ? positionPrice(asking, Number(price.year) as ModelYear, miles !== null && miles >= 0 ? miles : null) : null;

  const extra = (i: BuyItem) => i.extra ? <span className="small"> · {t(`buy.extra.${i.extra.key}` as MsgKey)}: {i.extra.value}</span> : null;

  return (
    <>
      <h1>{t('nav.buy')}</h1>
      <p className="lede">{t('buy.lede')}</p>
      <Note>{t('buy.disclaimer')}</Note>

      <section className="card" aria-labelledby="buy-vin">
        <h2 id="buy-vin">{t('buy.vinTitle')}</h2>
        <label>{t('vin.enter')}
          <input className="input" value={vin} onChange={(e) => setVin(e.target.value)} autoComplete="off" spellCheck={false} maxLength={24} />
        </label>
        {v && !v.valid && <p className="err" role="alert">{t('vin.invalid')}: {v.errors.join(' ')}</p>}
        {v?.valid && (
          <div role="status">
            <p>{v.year ? t('buy.vinYear', { y: v.year }) : t('buy.vinNoYear')}{v.isGT500 ? '' : ` — ${t('buy.vinNotGt500')}`}</p>
            {v.year && <button className="btn" onClick={() => setYear(v.year)}>{t('buy.useYear', { y: v.year })}</button>}
            {vinRecalls.length > 0 && (
              <>
                <h3>{t('buy.askRecalls', { n: vinRecalls.length })}</h3>
                <ul className="rows small">
                  {vinRecalls.map((r) => (
                    <li key={r.id}><strong>{r.campaign ?? r.id}</strong> — {r.title}
                      <div className="muted">{r.appliesToGT500 ? t(`report.applies.${r.appliesToGT500}` as MsgKey) : ''}{r.buildWindow ? ` · ${t('report.build')}: ${r.buildWindow}` : ''}</div>
                      <Cite c={r.confidence} url={r.source} /></li>
                  ))}
                </ul>
              </>
            )}
          </div>
        )}
        <p className="small muted">{t('buy.vinLookup')} <a href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">NHTSA ↗</a> · <a href={VPIC_URL} target="_blank" rel="noopener noreferrer">vPIC ↗</a> · <Link to="/vin">{t('nav.vin')} →</Link></p>
      </section>

      <section className="card" aria-labelledby="buy-price">
        <h2 id="buy-price">{t('buy.priceTitle')}</h2>
        <p className="small muted">{t('buy.priceNote')}</p>
        <div className="form four">
          <label>{t('buy.asking')}<input className="input" inputMode="numeric" value={price.asking} onChange={(e) => setPrice({ ...price, asking: e.target.value })} /></label>
          <label>{t('garage.year')}
            <select className="input" value={price.year} onChange={(e) => setPrice({ ...price, year: e.target.value as typeof price.year })}>
              <option value="">—</option>{YEARS.map((y) => <option key={y} value={y}>{y}</option>)}
            </select>
          </label>
          <label>{t('buy.miles')}<input className="input" inputMode="numeric" value={price.miles} onChange={(e) => setPrice({ ...price, miles: e.target.value })} /></label>
        </div>
        {pos && asking !== null && (
          <div role="status" aria-live="polite">
            {pos.points.length === 0 ? <p>{t('buy.noSales', { y: price.year })}</p> : (
              <>
                <p><strong>{t('buy.position', { a: usdWhole(asking), below: pos.below, above: pos.above, n: pos.points.length, y: price.year })}</strong></p>
                <p className="small">{t('buy.range', { min: usdWhole(pos.min ?? 0), med: usdWhole(pos.median ?? 0), max: usdWhole(pos.max ?? 0) })}</p>
                {pos.nearMiles.length > 0 && (
                  <>
                    <h3>{t('buy.nearMiles')}</h3>
                    <ul className="rows small">
                      {pos.nearMiles.map((r) => <li key={r.id}>{usdWhole(r.price)} · {(r.mileage as number).toLocaleString('en-US')} mi · {r.date ?? '—'}{r.venue ? ` · ${r.venue}` : ''} <Cite c={r.confidence} url={r.source} /></li>)}
                    </ul>
                  </>
                )}
              </>
            )}
            {pos.stats.length > 0 && (
              <>
                <h3>{t('buy.stats')}</h3>
                <ul className="rows small">
                  {pos.stats.map((s) => <li key={s.id}>{s.label}: {s.value === null ? '—' : usdWhole(s.value)}{s.sampleSize ? ` (n=${s.sampleSize})` : ''} <Cite c={s.confidence} url={s.source} /></li>)}
                </ul>
              </>
            )}
            <p className="small"><Link to="/market">{t('nav.market')} →</Link></p>
          </div>
        )}
      </section>

      <section className="card" aria-labelledby="buy-list">
        <h2 id="buy-list">{t('buy.listTitle')}</h2>
        <p className="small muted">{t('buy.listNote')}</p>
        <label>{t('buy.listYear')}
          <select className="input" value={year ?? ''} onChange={(e) => setYear(e.target.value ? (Number(e.target.value) as ModelYear) : null)}>
            <option value="">{t('buy.allYears')}</option>{YEARS.map((y) => <option key={y} value={y}>{y}</option>)}
          </select>
        </label>
        <p role="status">{t('buy.progress', { d: done, n: items.length })}</p>
        {saveErr && <p className="err" role="alert">{t('common.saveFailed')}</p>}
        {BUY_SECTIONS.map((sec) => {
          const list = items.filter((i) => i.section === sec);
          if (!list.length) return null;
          return (
            <div key={sec}>
              <h3 id={`buy-sec-${sec}`}>{t(`buy.sec.${sec}` as MsgKey)}</h3>
              <ul className="rows small" aria-labelledby={`buy-sec-${sec}`}>
                {list.map((i) => (
                  <li key={i.id}>
                    <label className="check">
                      <input type="checkbox" checked={checks.checked.includes(i.id)} onChange={(e) => commit(toggleCheck(checks, i.id, e.target.checked))} />
                      <span><strong>{i.title}</strong>{i.applies ? <span className="muted"> · {t(`report.applies.${i.applies}` as MsgKey)}</span> : null}{extra(i)}{i.detail ? <><br />{i.detail}</> : null}</span>
                    </label>
                    <Cite c={i.confidence} url={i.source} />
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
        <button className="btn" onClick={() => { if (confirm(t('buy.confirmReset'))) commit({ checked: [] }); }} disabled={!checks.checked.length}>{t('buy.reset')}</button>
      </section>
    </>
  );
}
