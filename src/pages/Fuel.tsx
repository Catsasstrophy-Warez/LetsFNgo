import { useState } from 'react';
import { useCarLog } from '../components/CarContext';
import { Link } from 'react-router';
import { Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { LineChart } from '../components/LineChart';
import { useT, useUnits } from '../components/SettingsContext';
import { loadGarage, today, uid } from '../lib/garage';
import { FUEL_KEY, fuelIntervals, fuelSummary, loadFuel, ownershipCost, type FillUp, type FuelType } from '../lib/fuel';
import { fmtQty, toDisplay, unitLabel } from '../lib/units';

const blank = (): Omit<FillUp, 'id'> => ({ date: today(), odometer: NaN, gallons: NaN, price: NaN, fuel: '93', blend: null, full: true, notes: '' });
const money = (n: number | null, d = 2) => (n === null ? '—' : `$${n.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d })}`);

export default function Fuel() {
  const u = useUnits();
  const t = useT();
  const FUELS: [FuelType, string][] = [['93', t('fuel.93')], ['E85', 'E85'], ['blend', t('fuel.blend')]];
  const [fills, setFills] = useCarLog<FillUp>(FUEL_KEY, loadFuel);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  const g = loadGarage();
  const iv = fuelIntervals(fills);
  const sum = fuelSummary(fills);
  const own = ownershipCost(fills, g.service, g.mods);
  const n = (v: number | null) => (v === null ? NaN : v);
  const ok = (v: number) => Number.isFinite(v) && v >= 0;
  // Price is per gallon internally; in metric it is entered per litre.
  const perL = u === 'metric' ? 3.785411784 : 1;
  const priceLabel = u === 'metric' ? t('fuel.priceL') : t('fuel.priceGal');

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!ok(f.odometer) || !(f.gallons > 0) || !ok(f.price)) return setErr(t('fuel.errMain'));
    if (f.fuel === 'blend' && (f.blend === null || f.blend < 0 || f.blend > 100)) return setErr(t('fuel.errBlend'));
    setErr('');
    setFills([...fills, { id: uid(), ...f, blend: f.fuel === 'blend' ? f.blend : f.fuel === 'E85' ? 85 : null }]);
    setF({ ...blank(), fuel: f.fuel, blend: f.blend, price: f.price });
  };

  const econ = (mpg: number) => toDisplay('economy', mpg, u);
  return (
    <>
      <h1>{t('fuel.title')}</h1>
      <p className="lede">{t('fuel.lede')}</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>{t('fuel.new')}</h2>
        <div className="form two">
          <label>{t('log.date')}<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <UnitInput label={t('log.odometer')} kind="distance" value={Number.isFinite(f.odometer) ? f.odometer : null} onChange={(v) => setF({ ...f, odometer: n(v) })} digits={0} />
          <UnitInput label={t('fuel.added')} kind="volume" value={Number.isFinite(f.gallons) ? f.gallons : null} onChange={(v) => setF({ ...f, gallons: n(v) })} digits={3} />
          <UnitInput label={priceLabel} kind={null} value={Number.isFinite(f.price) ? f.price / perL : null} onChange={(v) => setF({ ...f, price: v === null ? NaN : v * perL })} digits={3} />
        </div>
        <div role="radiogroup" aria-label={t('fuel.type')} className="seg">
          {FUELS.map(([v, l]) => <button type="button" key={v} role="radio" aria-checked={f.fuel === v} className={f.fuel === v ? 'on' : ''} onClick={() => setF({ ...f, fuel: v })}>{l}</button>)}
        </div>
        {f.fuel === 'blend' && <UnitInput label={t('fuel.blendPct')} kind={null} value={f.blend} onChange={(blend) => setF({ ...f, blend })} digits={0} />}
        {f.fuel !== '93' && <Note>{t('fuel.e85Note')}</Note>}
        <label className="check"><input type="checkbox" checked={f.full} onChange={(e) => setF({ ...f, full: e.target.checked })} /><span>{t('fuel.full')}</span></label>
        <label>{t('log.notes')}<input className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">{t('fuel.save')}</button>
      </form>

      <section className="card">
        <h2>{t('fuel.summary')}</h2>
        <div className="stats">
          <div className="stat"><div className="stat-v">{sum.avgMpg === null ? '—' : econ(sum.avgMpg).toFixed(1)}</div><div className="stat-l">{t('fuel.avg', { u: unitLabel('economy', u) })}</div></div>
          <div className="stat"><div className="stat-v">{sum.costPerMile === null ? '—' : money(u === 'metric' ? sum.costPerMile / 1.609344 : sum.costPerMile, 3)}</div><div className="stat-l">{t('fuel.costPer', { u: unitLabel('distance', u) })}</div></div>
          <div className="stat"><div className="stat-v">{money(sum.spend)}</div><div className="stat-l">{t('fuel.spend')}</div></div>
          <div className="stat"><div className="stat-v">{fmtQty('volume', sum.gallons, u, 1)}</div><div className="stat-l">{t('fuel.fills', { n: sum.fills })}</div></div>
        </div>
        <LineChart title={t('fuel.econChart', { u: unitLabel('economy', u) })} points={iv.map((x) => ({ label: x.date, value: econ(x.mpg) }))} format={(v) => v.toFixed(1)} unit={unitLabel('economy', u)} lowerIsBetter={u === 'metric'} />
        <LineChart title={t('fuel.costChart', { u: unitLabel('distance', u) })} points={iv.map((x) => ({ label: x.date, value: u === 'metric' ? x.costPerMile / 1.609344 : x.costPerMile }))} format={(v) => `$${v.toFixed(2)}`} unit={t('fuel.per', { u: unitLabel('distance', u) })} lowerIsBetter />
      </section>

      <section className="card">
        <h2>{t('fuel.own')}</h2>
        <dl className="facts">
          <div className="fact"><dt>{t('fuel.fuel')}</dt><dd className="val">{money(own.fuel)}</dd></div>
          <div className="fact"><dt>{t('garage.serviceLog')}</dt><dd className="val">{money(own.service)}</dd></div>
          <div className="fact"><dt>{t('garage.modsLog')}</dt><dd className="val">{money(own.mods)}</dd></div>
          <div className="fact"><dt>{t('fuel.total')}</dt><dd className="val">{money(own.total)}</dd></div>
          <div className="fact"><dt>{t('fuel.perDist', { u: unitLabel('distance', u) })}</dt><dd className="val">{own.perMile === null ? t('fuel.need2') : money(u === 'metric' ? own.perMile / 1.609344 : own.perMile)}</dd></div>
        </dl>
        <Note>{t('fuel.ownNote')} <Link to="/garage">{t('nav.garage')} →</Link></Note>
      </section>

      {fills.length === 0 ? <p className="muted">{t('fuel.empty')}</p> : (
        <section className="card">
          <h2>{t('fuel.list')}</h2>
          <ul className="rows">
            {[...fills].sort((a, b) => b.odometer - a.odometer).map((x) => (
              <li key={x.id}>
                <div className="row-main"><span><strong>{fmtQty('volume', x.gallons, u, 2)}</strong> <span className="tag">{x.fuel === 'blend' ? `E${x.blend ?? '?'}` : x.fuel}</span>{!x.full && <span className="tag">{t('fuel.partial')}</span>}
                  <span className="muted"> {x.date} · {fmtQty('distance', x.odometer, u)} · {money(x.gallons * x.price)}</span></span>
                  <button className="link-btn danger" onClick={() => setFills(fills.filter((y) => y.id !== x.id))} aria-label={t('fuel.delete', { d: x.date })}>{t('common.delete')}</button></div>
                {x.notes && <p className="wrap">{x.notes}</p>}
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
