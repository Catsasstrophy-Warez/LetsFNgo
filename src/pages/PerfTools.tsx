import { useState } from 'react';
import { UnitInput } from '../components/UnitInput';
import { useUnits } from '../components/SettingsContext';
import { convertSpec, fmtQty } from '../lib/units';
import { fmt } from '../components/Facts';
import { Cite, Note } from '../components/Facts';
import { specs } from '../data/specs';
import { performance } from '../data/performance';
import { foxQuarter, haleQuarter, powerToWeight } from '../lib/perf';

const hpSpec = specs.find((s) => s.id === 'hp')!;
const wtSpec = specs.find((s) => s.id === 'curb-weight')!;
const best = performance.find((p) => p.id === 'best-stock')!;
const num = (s: string) => { const n = Number(s.replace(/,/g, '')); return Number.isFinite(n) && n > 0 ? n : 0; };

export default function PerfTools() {
  const [hp, setHp] = useState(String(hpSpec.value));
  const u = useUnits();
  const [wtN, setWt] = useState<number | null>(4225);
  const [driverN, setDriver] = useState<number | null>(180);
  const wt = String(wtN ?? 0), driver = String(driverN ?? 0);
  const race = num(wt) + num(driver);
  const h = haleQuarter(race, num(hp));
  const f = foxQuarter(race, num(hp));
  const p = powerToWeight(num(wt), num(hp));
  return (
    <>
      <h1>Performance Tools</h1>
      <p className="lede">Rule-of-thumb quarter-mile and power-to-weight math. Results are <strong>estimates</strong>, not measurements.</p>
      <section className="card">
        <div className="form two">
          <label>Horsepower (crank)<input className="input" inputMode="numeric" value={hp} onChange={(e) => setHp(e.target.value)} /></label>
          <UnitInput label="Car weight" kind="weight" value={wtN} onChange={setWt} digits={0} />
          <UnitInput label="Driver + fuel extra" kind="weight" value={driverN} onChange={setDriver} digits={0} />
        </div>
        <p className="muted">Stock: {String(hpSpec.value)} hp <Cite c={hpSpec.confidence} url={hpSpec.source} /> · curb weight {(() => { const c = convertSpec(wtSpec.value!, wtSpec.unit, u); return fmt(c.value, c.unit); })()} (sources conflict) <Cite c={wtSpec.confidence} url={wtSpec.source} /></p>
      </section>
      <section className="card">
        <h2>Quarter-mile estimate <span className="badge badge-unverified">estimate</span></h2>
        {h && f ? (
          <table className="tbl">
            <thead><tr><th>Formula</th><th>ET</th><th>Trap</th></tr></thead>
            <tbody>
              <tr><td>Hale (5.825·∛(W/hp), 234·∛(hp/W))</td><td>{h.et.toFixed(2)} s</td><td>{fmtQty('speed', h.mph, u, 1)}</td></tr>
              <tr><td>Fox (6.290·∛(W/hp), 224·∛(hp/W))</td><td>{f.et.toFixed(2)} s</td><td>{fmtQty('speed', f.mph, u, 1)}</td></tr>
            </tbody>
          </table>
        ) : <p className="err">Enter positive weight and horsepower.</p>}
        <p className="muted">Race weight used: {fmtQty('weight', race, u)}.</p>
        <Note>These formulas assume ideal traction and typical gearing; they are not sourced test results. For comparison, the best attributable stock pass is {best.result} <Cite c={best.confidence} url={best.source} />.</Note>
      </section>
      <section className="card">
        <h2>Power-to-weight</h2>
        {p ? (
          <dl className="facts">
            <div className="fact"><dt>lb per hp</dt><dd className="val">{p.lbPerHp.toFixed(2)}</dd></div>
            <div className="fact"><dt>hp per ton (2,000 lb)</dt><dd className="val">{p.hpPerTon.toFixed(0)}</dd></div>
            <div className="fact"><dt>kg per kW</dt><dd className="val">{p.kgPerKw.toFixed(2)}</dd></div>
            <div className="fact"><dt>W per kg</dt><dd className="val">{p.wPerKg.toFixed(0)}</dd></div>
          </dl>
        ) : <p className="err">Enter positive weight and horsepower.</p>}
        <Note>Uses car weight only (no driver).</Note>
      </section>
    </>
  );
}
