import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { LineChart } from '../components/LineChart';
import { useUnits } from '../components/SettingsContext';
import { save } from '../lib/storage';
import { loadGarage, today, uid } from '../lib/garage';
import { FUEL_KEY, fuelIntervals, fuelSummary, loadFuel, ownershipCost, type FillUp, type FuelType } from '../lib/fuel';
import { fmtQty, toDisplay, unitLabel } from '../lib/units';

const blank = (): Omit<FillUp, 'id'> => ({ date: today(), odometer: NaN, gallons: NaN, price: NaN, fuel: '93', blend: null, full: true, notes: '' });
const money = (n: number | null, d = 2) => (n === null ? '—' : `$${n.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d })}`);
const FUELS: [FuelType, string][] = [['93', '93 octane'], ['E85', 'E85'], ['blend', 'Ethanol blend']];

export default function Fuel() {
  const u = useUnits();
  const [fills, setFills] = useState<FillUp[]>(loadFuel);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  useEffect(() => { save(FUEL_KEY, fills); }, [fills]);
  const g = loadGarage();
  const iv = fuelIntervals(fills);
  const sum = fuelSummary(fills);
  const own = ownershipCost(fills, g.service, g.mods);
  const n = (v: number | null) => (v === null ? NaN : v);
  const ok = (v: number) => Number.isFinite(v) && v >= 0;
  // Price is per gallon internally; in metric it is entered per litre.
  const perL = u === 'metric' ? 3.785411784 : 1;
  const priceLabel = `Price per ${u === 'metric' ? 'L' : 'gal'} ($)`;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!ok(f.odometer) || !(f.gallons > 0) || !ok(f.price)) return setErr('Enter odometer, fuel amount and price.');
    if (f.fuel === 'blend' && (f.blend === null || f.blend < 0 || f.blend > 100)) return setErr('Enter the blend ethanol % (0–100).');
    setErr('');
    setFills([...fills, { id: uid(), ...f, blend: f.fuel === 'blend' ? f.blend : f.fuel === 'E85' ? 85 : null }]);
    setF({ ...blank(), fuel: f.fuel, blend: f.blend, price: f.price });
  };

  const econ = (mpg: number) => toDisplay('economy', mpg, u);
  return (
    <>
      <h1>Fuel &amp; Cost Log</h1>
      <p className="lede">Log fill-ups to track fuel economy and running costs. Economy is calculated full-tank to full-tank; partial fills are added to the next full one.</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>New fill-up</h2>
        <div className="form two">
          <label>Date<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <UnitInput label="Odometer" kind="distance" value={Number.isFinite(f.odometer) ? f.odometer : null} onChange={(v) => setF({ ...f, odometer: n(v) })} digits={0} />
          <UnitInput label="Fuel added" kind="volume" value={Number.isFinite(f.gallons) ? f.gallons : null} onChange={(v) => setF({ ...f, gallons: n(v) })} digits={3} />
          <UnitInput label={priceLabel} kind={null} value={Number.isFinite(f.price) ? f.price / perL : null} onChange={(v) => setF({ ...f, price: v === null ? NaN : v * perL })} digits={3} />
        </div>
        <div role="radiogroup" aria-label="Fuel type" className="seg">
          {FUELS.map(([v, l]) => <button type="button" key={v} role="radio" aria-checked={f.fuel === v} className={f.fuel === v ? 'on' : ''} onClick={() => setF({ ...f, fuel: v })}>{l}</button>)}
        </div>
        {f.fuel === 'blend' && <UnitInput label="Ethanol % in blend" kind={null} value={f.blend} onChange={(blend) => setF({ ...f, blend })} digits={0} />}
        {f.fuel !== '93' && <Note>Running E85 or blends needs a fuel system and tune built for it. Ford's fuel recommendation for the stock car is not sourced in this app — check your owner's manual.</Note>}
        <label className="check"><input type="checkbox" checked={f.full} onChange={(e) => setF({ ...f, full: e.target.checked })} /><span>Filled to full</span></label>
        <label>Notes<input className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">Save fill-up</button>
      </form>

      <section className="card">
        <h2>Summary</h2>
        <div className="stats">
          <div className="stat"><div className="stat-v">{sum.avgMpg === null ? '—' : econ(sum.avgMpg).toFixed(1)}</div><div className="stat-l">Avg {unitLabel('economy', u)}</div></div>
          <div className="stat"><div className="stat-v">{sum.costPerMile === null ? '—' : money(u === 'metric' ? sum.costPerMile / 1.609344 : sum.costPerMile, 3)}</div><div className="stat-l">Fuel cost / {unitLabel('distance', u)}</div></div>
          <div className="stat"><div className="stat-v">{money(sum.spend)}</div><div className="stat-l">Fuel spend</div></div>
          <div className="stat"><div className="stat-v">{fmtQty('volume', sum.gallons, u, 1)}</div><div className="stat-l">{sum.fills} fill-up(s)</div></div>
        </div>
        <LineChart title={`Fuel economy (${unitLabel('economy', u)})`} points={iv.map((x) => ({ label: x.date, value: econ(x.mpg) }))} format={(v) => v.toFixed(1)} unit={unitLabel('economy', u)} lowerIsBetter={u === 'metric'} />
        <LineChart title={`Fuel cost per ${unitLabel('distance', u)}`} points={iv.map((x) => ({ label: x.date, value: u === 'metric' ? x.costPerMile / 1.609344 : x.costPerMile }))} format={(v) => `$${v.toFixed(2)}`} unit={`per ${unitLabel('distance', u)}`} lowerIsBetter />
      </section>

      <section className="card">
        <h2>Ownership cost</h2>
        <dl className="facts">
          <div className="fact"><dt>Fuel</dt><dd className="val">{money(own.fuel)}</dd></div>
          <div className="fact"><dt>Service log</dt><dd className="val">{money(own.service)}</dd></div>
          <div className="fact"><dt>Mods log</dt><dd className="val">{money(own.mods)}</dd></div>
          <div className="fact"><dt>Total</dt><dd className="val">{money(own.total)}</dd></div>
          <div className="fact"><dt>Per {unitLabel('distance', u)}</dt><dd className="val">{own.perMile === null ? 'Log 2+ fill-ups' : money(u === 'metric' ? own.perMile / 1.609344 : own.perMile)}</dd></div>
        </dl>
        <Note>Service and mod costs come from the cost field in your <Link to="/garage">Garage</Link> logs. Per-distance cost uses the odometer span covered by the fuel log. Excludes purchase price, insurance and depreciation.</Note>
      </section>

      {fills.length === 0 ? <p className="muted">No fill-ups logged yet.</p> : (
        <section className="card">
          <h2>Fill-ups</h2>
          <ul className="rows">
            {[...fills].sort((a, b) => b.odometer - a.odometer).map((x) => (
              <li key={x.id}>
                <div className="row-main"><span><strong>{fmtQty('volume', x.gallons, u, 2)}</strong> <span className="tag">{x.fuel === 'blend' ? `E${x.blend ?? '?'}` : x.fuel}</span>{!x.full && <span className="tag">partial</span>}
                  <span className="muted"> {x.date} · {fmtQty('distance', x.odometer, u)} · {money(x.gallons * x.price)}</span></span>
                  <button className="link-btn danger" onClick={() => setFills(fills.filter((y) => y.id !== x.id))} aria-label={`Delete fill-up ${x.date}`}>Delete</button></div>
                {x.notes && <p className="wrap">{x.notes}</p>}
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
