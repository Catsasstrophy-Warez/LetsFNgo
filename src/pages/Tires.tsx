import { useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { useUnits } from '../components/SettingsContext';
import { GT500_FINAL, GT500_RATIOS, GT500_REAR_TIRE, GT500_REDLINE, TIRE_SPECS } from '../lib/gearing';
import { compareTires } from '../lib/tires';
import { fmtQty } from '../lib/units';

const pct = (n: number) => `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(2)}%`;

export default function Tires() {
  const u = useUnits();
  const [stock, setStock] = useState(GT500_REAR_TIRE);
  const [alt, setAlt] = useState('315/35R20');
  const [gear, setGear] = useState(6);
  const c = compareTires(stock, alt, GT500_RATIOS, GT500_FINAL, GT500_REDLINE);
  const len = (inches: number) => fmtQty('length', inches, u, u === 'metric' ? 0 : 2);
  const rows = c ? [
    ['Overall diameter', len(c.stock.diameterIn), len(c.alt.diameterIn)],
    ['Sidewall height', len(c.stock.sidewallIn), len(c.alt.sidewallIn)],
    ['Section width', len(c.stock.widthIn), len(c.alt.widthIn)],
    ['Circumference', len(c.stock.circumferenceIn), len(c.alt.circumferenceIn)],
    [u === 'metric' ? 'Revs per km' : 'Revs per mile', (u === 'metric' ? c.stock.revsPerMile / 1.609344 : c.stock.revsPerMile).toFixed(0), (u === 'metric' ? c.alt.revsPerMile / 1.609344 : c.alt.revsPerMile).toFixed(0)],
  ] : [];
  return (
    <>
      <h1>Tire &amp; Wheel Calculator</h1>
      <p className="lede">Compare the stock tire with another size: diameter, revs per {u === 'metric' ? 'km' : 'mile'}, speedometer error and the gearing effect, using the sourced TR-9070 ratios and {GT500_FINAL} final drive. Geometric (unloaded) sizes — real rolling diameter is a little smaller.</p>
      <section className="card">
        <div className="form two">
          <label>Stock tire<input className="input mono" value={stock} onChange={(e) => setStock(e.target.value)} /></label>
          <label>Alternate tire<input className="input mono" value={alt} onChange={(e) => setAlt(e.target.value)} /></label>
        </div>
        <ul className="rows small">{TIRE_SPECS.map((s) => <li key={s.id}>{s.label}: {String(s.value)} <Cite c={s.confidence} url={s.source} /></li>)}</ul>
      </section>
      {!c ? <p className="err" role="alert">Enter sizes like 315/30R20 or 305/30ZR19.</p> : (
        <>
          <section className="card hl" aria-live="polite">
            <h2>Result</h2>
            <p className="stat-v">{pct(c.diameterPct)}<small>diameter</small></p>
            <p>When the speedometer shows <strong>{fmtQty('speed', 60, u)}</strong> you are doing about <strong>{fmtQty('speed', c.actualAt(60), u, 1)}</strong> ({c.speedoErrorPct >= 0 ? 'reads low' : 'reads high'} by {Math.abs(c.speedoErrorPct).toFixed(1)}%).</p>
            <p>Effective final drive: <strong>{c.effectiveFinal.toFixed(2)}</strong> (vs {GT500_FINAL.toFixed(2)} with the stock tire){c.diameterPct > 0 ? ' — taller tire, slightly "taller" gearing.' : c.diameterPct < 0 ? ' — shorter tire, slightly "shorter" gearing.' : '.'}</p>
            {Math.abs(c.diameterPct) > 3 && <p className="warn-t">More than 3% diameter change: expect noticeable speedometer error and check fitment and clearance.</p>}
          </section>
          <section className="card">
            <h2>Sizes</h2>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Tire size comparison">
              <table className="tbl"><thead><tr><th scope="col">Figure</th><th scope="col">Stock</th><th scope="col">Alternate</th></tr></thead>
                <tbody>{rows.map(([k, a, b]) => <tr key={k}><th scope="row">{k}</th><td>{a}</td><td>{b}</td></tr>)}</tbody></table>
            </div>
          </section>
          <section className="card">
            <h2>Gearing effect</h2>
            <label className="form-label">Gear for rpm table
              <select className="input" value={gear} onChange={(e) => setGear(Number(e.target.value))}>{GT500_RATIOS.map((g, i) => <option key={i} value={i + 1}>{i + 1} ({g.toFixed(2)})</option>)}</select></label>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Rpm at speed">
              <table className="tbl"><thead><tr><th scope="col">Speed</th><th scope="col">Stock rpm</th><th scope="col">Alt rpm</th></tr></thead>
                <tbody>{[40, 60, 70, 80].map((mph) => { const r = c.rpmAt(mph, GT500_RATIOS[gear - 1]); return <tr key={mph}><th scope="row">{fmtQty('speed', mph, u)}</th><td>{r.stock.toFixed(0)}</td><td>{r.alt.toFixed(0)}</td></tr>; })}</tbody></table>
            </div>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Speed at redline per gear">
              <table className="tbl"><thead><tr><th scope="col">Gear</th><th scope="col">Stock @ {GT500_REDLINE.toLocaleString('en-US')} rpm</th><th scope="col">Alternate</th></tr></thead>
                <tbody>{c.topSpeedPerGear.map((g) => <tr key={g.gear}><th scope="row">{g.gear}</th><td>{fmtQty('speed', g.stock, u)}</td><td>{fmtQty('speed', g.alt, u)}</td></tr>)}</tbody></table>
            </div>
            <Note>Theoretical speed at redline; the GT500's real top speed is electronically limited. See also <Link to="/gearing">Gear &amp; Speed</Link>.</Note>
          </section>
        </>
      )}
    </>
  );
}
