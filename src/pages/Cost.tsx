import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { ChartTable } from '../components/ChartA11y';
import { useCar } from '../components/CarContext';
import { useT } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';
import { usdFixed, usdWhole } from '../lib/format';
import { activeCar, carLabel, forCar, loadCars, loadTrack } from '../lib/garage';
import { loadFuel } from '../lib/fuel';
import { INSURANCE_POINTS, estimate, loggedCosts, servicePricing, valuePoints, yearOf, type CostLine } from '../lib/cost';
import { inputsFor, loadCost, posNum, saveCost, withInputs, type CostInputs } from '../lib/costStore';

type NumField = 'annualMiles' | 'years' | 'fuelPrice' | 'insurance' | 'tireSet' | 'tireLife' | 'purchasePrice';
const FIELDS: { k: NumField; step: string }[] = [
  { k: 'annualMiles', step: '1' }, { k: 'years', step: '1' }, { k: 'fuelPrice', step: '0.01' }, { k: 'insurance', step: '1' },
  { k: 'tireSet', step: '1' }, { k: 'tireLife', step: '1' }, { k: 'purchasePrice', step: '1' },
];

/** Badge saying whose number a value is: the owner's own, or a sourced figure. */
function Origin({ o }: { o: 'user' | 'sourced' | 'mixed' }) {
  const t = useT();
  return <span className={`origin origin-${o}`}>{t(`cost.origin.${o}` as MsgKey)}</span>;
}

/** Cost of ownership: estimated cost per year and per mile for the active Garage car. */
export default function Cost() {
  const t = useT();
  const { active, version } = useCar();
  const car = useMemo(() => { void version; void active; const s = loadCars(); return { c: activeCar(s), i: s.cars.findIndex((x) => x.id === activeCar(s).id) }; }, [active, version]);
  const [store, setStore] = useState(loadCost);
  const [saveErr, setSaveErr] = useState(false);
  const inp = inputsFor(store, car.c.id);
  const commit = (next: CostInputs) => { const s = withInputs(store, car.c.id, next); setStore(s); setSaveErr(!saveCost(s)); };
  const num = (v: string) => posNum(v.trim() === '' ? null : Number(v));

  const logged = useMemo(() => loggedCosts(forCar(loadFuel(), car.c.id), car.c.service, car.c.mods, forCar(loadTrack(), car.c.id).length), [car]);
  const est = estimate(inp, logged.mpg);
  const year = yearOf(car.c.year);
  const points = valuePoints(year, inp.purchasePrice);
  const name = carLabel(car.c, car.i);

  const lineLabel = (l: CostLine) => (l.kind === 'service' ? t(`cost.svc.${l.id}` as MsgKey) : t(`cost.kind.${l.kind}` as MsgKey));
  const pricedLines = est.lines.filter((l): l is CostLine & { perYear: number } => l.perYear !== null && l.perYear > 0);
  const max = Math.max(1, ...pricedLines.map((l) => l.perYear));
  const W = 600, ROW = 30, LABEL = 210, BAR = W - LABEL - 90;

  return (
    <>
      <h1>{t('nav.cost')}</h1>
      <p className="lede">{t('cost.lede', { c: name })}</p>
      <Note>{t('cost.disclaimer')}</Note>

      <section className="card no-print" aria-labelledby="cost-inputs">
        <h2 id="cost-inputs">{t('cost.inputsTitle')}</h2>
        <p className="small muted">{t('cost.inputsNote')}</p>
        <div className="grid2">
          {FIELDS.map(({ k, step }) => (
            <label key={k}>{t(`cost.in.${k}` as MsgKey)}
              <input className="input" type="number" inputMode="decimal" min="0" step={step} value={inp[k] ?? ''}
                onChange={(e) => commit({ ...inp, [k]: num(e.target.value) })} />
            </label>
          ))}
        </div>
        {INSURANCE_POINTS.length > 0 && (
          <div className="small" aria-labelledby="cost-ins-ref">
            <p id="cost-ins-ref"><strong>{t('cost.insRefTitle')}</strong> <span className="muted">{t('cost.insRefNote')}</span></p>
            <ul>
              {INSURANCE_POINTS.map((m) => (
                <li key={m.id}>{m.item.replace(/^Insurance data point: /, '')}: {t('cost.insRefVal', { a: usdWhole(Number(m.value)) })} <Origin o="sourced" /> <Cite c={m.confidence} url={m.source} />
                  {m.context && <span className="muted"> — {m.context}</span>}{m.note && <div className="muted">{m.note}</div>}</li>
              ))}
            </ul>
          </div>
        )}
        {saveErr && <p className="err" role="alert">{t('cost.saveErr')}</p>}
      </section>

      <section className="card" aria-labelledby="cost-breakdown">
        <h2 id="cost-breakdown">{t('cost.breakdownTitle')}</h2>
        {!est.ready ? <p role="status">{t('cost.needInputs')}</p> : (
          <>
            <table className="print-tbl">
              <caption className="small muted">{t('cost.caption', { m: inp.annualMiles!.toLocaleString('en-US'), y: inp.years! })}</caption>
              <thead><tr><th scope="col">{t('cost.colItem')}</th><th scope="col">{t('cost.colBasis')}</th><th scope="col">{t('cost.colYear')}</th></tr></thead>
              <tbody>
                {est.lines.map((l) => (
                  <tr key={l.id}>
                    <th scope="row">{lineLabel(l)}</th>
                    <td className="small">
                      {l.kind === 'service' && <>
                        {t('cost.times', { n: l.times! })} <span className="muted">{t('cost.interval')}</span> <Cite c={l.confidence!} url={l.source!} />
                        <label className="block no-print">{t('cost.yourPrice', { s: lineLabel(l) })}
                          <input className="input" type="number" inputMode="decimal" min="0" step="0.01" value={inp.servicePrices[l.id] ?? ''}
                            onChange={(e) => { const n = num(e.target.value); const sp = { ...inp.servicePrices }; if (n === null) delete sp[l.id]; else sp[l.id] = n; commit({ ...inp, servicePrices: sp }); }} />
                        </label>
                        {l.unitPrice != null && <div>{t('cost.each', { a: usdFixed(l.unitPrice) })} <Origin o={l.priceOrigin!} /></div>}
                        {servicePricing(l.id).parts.filter((p) => p.price).map((p) => (
                          <div key={p.part.id} className="muted">{t(p.price!.per === 'quart' ? 'cost.partPerQt' : p.price!.per === 'listing' ? 'cost.partListing' : 'cost.partEach', { n: p.part.number, a: usdFixed(p.price!.value!), d: p.price!.dateSeen })} <Cite c={p.price!.confidence} url={p.price!.source} />
                            {p.reason === 'no-capacity' && <> {t('cost.noCapacity')}</>}{p.reason === 'unclear-pack' && <> {t('cost.unclearPack')}</>}</div>
                        ))}
                        {l.priceOrigin !== 'sourced' && servicePricing(l.id).parts.some((p) => !p.price) && <div className="muted">{t('cost.partsUnpriced', { n: servicePricing(l.id).parts.filter((p) => !p.price).map((p) => p.part.number).join(', ') })}</div>}
                      </>}
                      {l.kind === 'fuel' && (l.mpg
                        ? <>{t('cost.mpgUsed', { m: l.mpg.value.toFixed(1) })} <Origin o={l.mpg.origin} />{l.mpg.source && <> <Cite c={l.mpg.confidence!} url={l.mpg.source} /></>}
                          {inp.fuelPrice !== null && <div>{t('cost.fuelAt', { p: usdFixed(inp.fuelPrice) })} <Origin o="user" /></div>}</>
                        : t('cost.noMpg'))}
                      {(l.kind === 'insurance' || l.kind === 'tires') && l.perYear !== null && <Origin o="user" />}
                      {l.kind === 'tires' && l.perYear === null && <span className="muted">{t('cost.tiresNeed')}</span>}
                    </td>
                    <td>{l.perYear === null ? <span className="muted">{l.kind === 'service' ? t('cost.unsourced') : t('cost.notEntered')}</span> : <strong>{usdWhole(l.perYear)}</strong>}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr><th scope="row" colSpan={2}>{t('cost.perYear')}</th>
                  <td role="status"><strong>{est.atLeast ? t('cost.atLeast', { a: usdWhole(est.perYear) }) : usdWhole(est.perYear)}</strong>
                    {est.unpriced > 0 && <div className="small muted">{t('cost.unpricedCount', { n: est.unpriced })}</div>}</td></tr>
                <tr><th scope="row" colSpan={2}>{t('cost.totalYears', { y: inp.years! })}</th>
                  <td><strong>{est.atLeast ? t('cost.atLeast', { a: usdWhole(est.total) }) : usdWhole(est.total)}</strong></td></tr>
                <tr><th scope="row" colSpan={2}>{t('cost.perMile')}</th>
                  <td><strong>{est.perMile === null ? '—' : est.atLeast ? t('cost.atLeast', { a: usdFixed(est.perMile) }) : usdFixed(est.perMile)}</strong></td></tr>
              </tfoot>
            </table>
            {est.notDue.length > 0 && <p className="small muted">{t('cost.notDue', { s: est.notDue.map((s) => t(`cost.svc.${s.id}` as MsgKey)).join(', ') })}</p>}

            <h3 id="cost-chart-title">{t('cost.chartTitle')}</h3>
            {pricedLines.length === 0 ? <p className="small muted">{t('cost.chartEmpty')}</p> : (
              <>
                <svg className="cost-chart" viewBox={`0 0 ${W} ${pricedLines.length * ROW + 8}`} role="img" aria-labelledby="cost-chart-title">
                  {pricedLines.map((l, i) => (
                    <g key={l.id} aria-hidden="true">
                      <text className="cost-chart-label" x={LABEL - 8} y={i * ROW + 20} textAnchor="end">{lineLabel(l).slice(0, 28)}</text>
                      <rect className="cost-chart-bar" x={LABEL} y={i * ROW + 6} height={ROW - 10} width={Math.max(2, (l.perYear / max) * BAR)} rx={3} />
                      <text className="cost-chart-val" x={LABEL + Math.max(2, (l.perYear / max) * BAR) + 6} y={i * ROW + 20}>{usdWhole(l.perYear)}</text>
                    </g>
                  ))}
                </svg>
                <ChartTable>
                  <table>
                    <caption>{t('cost.chartTitle')}</caption>
                    <thead><tr><th scope="col">{t('cost.colItem')}</th><th scope="col">{t('cost.colYear')}</th></tr></thead>
                    <tbody>{pricedLines.map((l) => <tr key={l.id}><th scope="row">{lineLabel(l)}</th><td>{usdWhole(l.perYear)}</td></tr>)}</tbody>
                  </table>
                </ChartTable>
              </>
            )}
          </>
        )}
        <div className="btn-row no-print">
          <button className="btn ghost" onClick={() => window.print()}>{t('cost.print')}</button>
        </div>
      </section>

      <section className="card" aria-labelledby="cost-logged">
        <h2 id="cost-logged">{t('cost.loggedTitle')} <Origin o="user" /></h2>
        <p className="small muted">{t('cost.loggedNote')}</p>
        <table className="print-tbl">
          <caption className="sr-only">{t('cost.loggedTitle')}</caption>
          <tbody>
            <tr><th scope="row">{t('cost.log.fuel', { n: logged.fills })}</th><td>{usdWhole(logged.fuel)}</td></tr>
            <tr><th scope="row">{t('cost.log.service', { n: logged.serviceEntries })}</th><td>{usdWhole(logged.service)}</td></tr>
            <tr><th scope="row">{t('cost.log.mods', { n: logged.modEntries })}</th><td>{usdWhole(logged.mods)}</td></tr>
            <tr><th scope="row">{t('cost.log.total')}</th><td><strong>{usdWhole(logged.total)}</strong></td></tr>
            <tr><th scope="row">{t('cost.log.perMile')}</th><td>{logged.perMile === null ? t('cost.log.noMiles') : t('cost.log.perMileVal', { a: usdFixed(logged.perMile), m: logged.miles.toLocaleString('en-US') })}</td></tr>
            <tr><th scope="row">{t('cost.log.mpg')}</th><td>{logged.mpg === null ? t('cost.log.noMpg') : logged.mpg.toFixed(1)}</td></tr>
            <tr><th scope="row">{t('cost.log.track')}</th><td>{t('cost.log.trackVal', { n: logged.trackSessions })}</td></tr>
          </tbody>
        </table>
        <p className="no-print"><Link to="/fuel">{t('nav.fuel')}</Link> · <Link to="/garage">{t('nav.garage')}</Link> · <Link to="/track">{t('nav.track')}</Link></p>
      </section>

      <section className="card" aria-labelledby="cost-value">
        <h2 id="cost-value">{t('cost.valueTitle')}</h2>
        <p className="small muted">{t('cost.valueNote')}</p>
        {year === null ? <p>{t('cost.noYear')} <Link to="/garage">{t('nav.garage')}</Link></p> : (
          <>
            <p>{inp.purchasePrice === null ? t('cost.noPurchase') : <>{t('cost.paid', { a: usdWhole(inp.purchasePrice) })} <Origin o="user" /></>}</p>
            {points.length === 0 ? <p>{t('cost.noPoints', { y: year })}</p> : (
              <table className="print-tbl">
                <caption className="small muted">{t('cost.pointsCaption', { y: year })}</caption>
                <thead><tr><th scope="col">{t('cost.colPoint')}</th><th scope="col">{t('cost.colValue')}</th><th scope="col">{t('cost.colDiff')}</th></tr></thead>
                <tbody>
                  {points.map((p) => (
                    <tr key={p.id}>
                      <th scope="row">{p.kind === 'stat' ? p.label : t('cost.auctionMedian', { y: year })}
                        {p.n ? <span className="small muted"> ({t('cost.sample', { n: p.n })})</span> : null}</th>
                      <td>{usdWhole(p.value)} <Origin o="sourced" /> {p.source ? <Cite c={p.confidence!} url={p.source} /> : <Link className="small" to="/market">{t('cost.seeMarket')}</Link>}</td>
                      <td>{p.diff === null ? '—' : `${p.diff >= 0 ? '+' : '−'}${usdWhole(Math.abs(p.diff))}`}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </>
        )}
      </section>
    </>
  );
}
