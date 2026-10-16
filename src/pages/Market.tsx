import { useState } from 'react';
import { Link } from 'react-router';
import { auctionResults as ALL, marketStats as STATS } from '../data/auctions';
import type { AuctionResult, MarketStat, ModelYear } from '../data/types';
import { Cite, Conflicts, Note } from '../components/Facts';
import { ScatterChart } from '../components/ScatterChart';
import { useT, useUnits } from '../components/SettingsContext';
import { DEFAULT_FILTER, byDate, byMileage, filterAuctions, median, priced, usd0, type MarketFilter } from '../lib/market';
import { loadGarage, toNum } from '../lib/garage';
import { fmtQty, toDisplay, unitLabel } from '../lib/units';

type Tri = 'any' | 'yes' | 'no';
const tri = (v: boolean | null): Tri => (v === null ? 'any' : v ? 'yes' : 'no');
const fromTri = (v: Tri): boolean | null => (v === 'any' ? null : v === 'yes');
const monthLabel = (x: number) => { const y = Math.floor(x); const m = Math.min(12, Math.floor((x - y) * 12) + 1); return `${y}-${String(m).padStart(2, '0')}`; };

/** Market value: sourced auction results charted by date and mileage, with the owner's car marked. */
export default function Market({ results = ALL, stats = STATS }: { results?: AuctionResult[]; stats?: MarketStat[] }) {
  const t = useT();
  const u = useUnits();
  const g = loadGarage();
  const [f, setF] = useState<MarketFilter>(DEFAULT_FILTER);
  const shown = filterAuctions(results, f);
  const pts = priced(shown);
  const med = median(pts.map((r) => r.price));
  const myMiles = toNum(g.odometer);
  const yesNo = (v: boolean | null) => (v === null ? t('market.notStated') : v ? t('common.yes') : t('common.no'));
  const triSel = (label: string, v: boolean | null, set: (x: boolean | null) => void) => (
    <label>{label}
      <select className="input" value={tri(v)} onChange={(e) => set(fromTri(e.target.value as Tri))}>
        <option value="any">{t('market.any')}</option><option value="yes">{t('common.yes')}</option><option value="no">{t('common.no')}</option>
      </select>
    </label>
  );
  const distX = (mi: number) => `${Math.round(toDisplay('distance', mi, u)).toLocaleString('en-US')}`;

  return (
    <>
      <h1>{t('market.title')}</h1>
      <p className="lede">{t('market.lede')}</p>
      {results.length === 0 ? (
        <section className="card" aria-labelledby="mk-empty">
          <h2 id="mk-empty">{t('market.emptyTitle')}</h2>
          <p className="muted">{t('market.empty')} <Link to="/packages">{t('nav.packages')} →</Link></p>
        </section>
      ) : (
        <>
          <section className="card" aria-labelledby="mk-f">
            <h2 id="mk-f">{t('market.filters')}</h2>
            <div className="form four">
              <label>{t('garage.year')}
                <select className="input" value={f.year ?? ''} onChange={(e) => setF({ ...f, year: e.target.value ? (Number(e.target.value) as ModelYear) : null })}>
                  <option value="">{t('market.allYears')}</option><option value="2020">2020</option><option value="2021">2021</option><option value="2022">2022</option>
                </select>
              </label>
              {triSel('CFTP', f.cftp, (cftp) => setF({ ...f, cftp }))}
              {triSel(t('market.heritage'), f.heritage, (heritage) => setF({ ...f, heritage }))}
            </div>
            <label className="check"><input type="checkbox" checked={f.includeOutliers} onChange={(e) => setF({ ...f, includeOutliers: e.target.checked })} /><span>{t('market.outliers')}</span></label>
            <label className="check"><input type="checkbox" checked={f.includeOffers} onChange={(e) => setF({ ...f, includeOffers: e.target.checked })} /><span>{t('market.offers')}</span></label>
            {g.year && <button className="link-btn" onClick={() => setF({ ...f, year: Number(g.year) as ModelYear })}>{t('market.myYear', { y: g.year })}</button>}
            <p className="muted" role="status">{t('market.count', { shown: shown.length, all: results.length, priced: pts.length })}</p>
            {(f.cftp !== null || f.heritage !== null) && <p className="muted small">{t('market.triNote')}</p>}
          </section>
          <section className="card">
            <h2>{t('market.charts')}</h2>
            {med !== null && <p>{t('market.median', { m: usd0(med), n: pts.length })}</p>}
            <ScatterChart title={t('market.byDate')} points={byDate(shown)} fmtX={monthLabel} fmtY={usd0} xLabel={t('market.saleDate')} yLabel={t('market.price')}
              refY={med !== null ? { y: med, label: t('market.medianShort', { m: usd0(med) }) } : undefined} tableLabel={t('chart.table')} empty={t('market.noPoints')} />
            <ScatterChart title={t('market.byMiles')} points={byMileage(shown)} fmtX={(mi) => distX(mi)} fmtY={usd0} xLabel={t('market.mileage', { u: unitLabel('distance', u) })} yLabel={t('market.price')}
              marker={myMiles !== null ? { x: myMiles, label: t('market.yourCar', { d: fmtQty('distance', myMiles, u) }) } : undefined} tableLabel={t('chart.table')} empty={t('market.noPoints')} />
            {myMiles === null && <p className="muted small">{t('market.setOdo')} <Link to="/garage#maintenance">{t('nav.garage')} →</Link></p>}
            <Note>{t('market.chartNote')}</Note>
          </section>
          <section className="card">
            <h2>{t('market.results')}</h2>
            {shown.length === 0 ? <p className="muted">{t('market.noMatch')}</p> : (
              <ul className="rows">
                {[...shown].sort((a, b) => (b.date ?? '').localeCompare(a.date ?? '')).map((r) => (
                  <li key={r.id}>
                    <div className="row-main"><strong>{r.price !== null ? usd0(r.price) : r.localPrice ? t('market.localOnly', { a: `${r.localPrice.currency} ${r.localPrice.amount.toLocaleString('en-US')}` }) : t('market.noPrice')}</strong>
                      <span className="muted small">{r.date ?? t('market.dateUnknown')}</span></div>
                    <div>{r.description}</div>
                    <div className="small muted">{[r.venue ?? t('market.venueUnknown'), String(r.year), r.mileage !== null ? fmtQty('distance', r.mileage, u) : t('market.milesUnknown'), `CFTP: ${yesNo(r.cftp)}`, `${t('market.heritage')}: ${yesNo(r.heritage)}`, r.outcome === 'offer' ? t('market.offer') : r.outcome === 'no-sale' ? t('market.noSale') : ''].filter(Boolean).join(' · ')}</div>
                    {r.outlier && <p className="warn-t small">{t('market.outlier')}: {r.outlier}</p>}
                    {r.conflicts && <Conflicts values={r.conflicts} />}
                    {r.note && <p className="small muted wrap">{r.note}</p>}
                    <Cite c={r.confidence} url={r.source} />
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
      {stats.length > 0 && (
        <section className="card">
          <h2>{t('market.stats')}</h2>
          <ul className="rows">
            {stats.map((s) => (
              <li key={s.id}>
                <div className="row-main"><span>{s.label} <span className="muted small">({s.year} {t('market.cars')}{s.sampleSize ? `, n=${s.sampleSize}` : ''})</span></span><strong>{s.value !== null ? usd0(s.value) : '—'}</strong></div>
                <Cite c={s.confidence} url={s.source} />
                {s.conflicts && <><div className="sub">{t('market.conflict')}</div><Conflicts values={s.conflicts} money /></>}
              </li>
            ))}
          </ul>
          <Note>{t('market.statsNote')}</Note>
        </section>
      )}
    </>
  );
}
