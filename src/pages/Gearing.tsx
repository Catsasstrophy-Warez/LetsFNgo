import { useState } from 'react';
import { Cite, Note } from '../components/Facts';
import {
  DIFF_SPEC, GT500_FINAL, GT500_RATIOS, GT500_REAR_TIRE, GT500_REDLINE, RATIO_SPEC, REDLINE_SPEC, TIRE_SPECS, TOP_SPEED_SPEC,
  mphAt, parseTireSize, rpmAt, tireDiameterIn,
} from '../lib/gearing';

const num = (s: string) => { const n = Number(s); return Number.isFinite(n) && n > 0 ? n : null; };

export default function Gearing() {
  const [rpm, setRpm] = useState(String(GT500_REDLINE));
  const [mph, setMph] = useState('60');
  const [fd, setFd] = useState(String(GT500_FINAL));
  const [tire, setTire] = useState(GT500_REAR_TIRE);
  const t = parseTireSize(tire);
  const dia = t ? tireDiameterIn(t) : null;
  const r = num(rpm), m = num(mph), f = num(fd);
  const limit = Number(TOP_SPEED_SPEC.value);
  const custom = f !== GT500_FINAL || tire.replace(/\s/g, '').toUpperCase() !== GT500_REAR_TIRE;

  return (
    <>
      <h1>Gear &amp; Speed Calculator</h1>
      <p className="lede">Road speed per gear from the TR-9070 ratios, final drive and rear tire size. Math only — tire growth, slip and the speed limiter are ignored.</p>
      <section className="card">
        <ul className="rows">
          <li>Ratios {GT500_RATIOS.join(' / ')} <Cite c={RATIO_SPEC.confidence} url={RATIO_SPEC.source} /></li>
          <li>Final drive {GT500_FINAL}:1 <Cite c={DIFF_SPEC.confidence} url={DIFF_SPEC.source} /></li>
          <li>Redline {GT500_REDLINE.toLocaleString('en-US')} rpm <Cite c={REDLINE_SPEC.confidence} url={REDLINE_SPEC.source} /></li>
          {TIRE_SPECS.map((s) => <li key={s.id}>{s.label} {String(s.value)} <Cite c={s.confidence} url={s.source} /></li>)}
        </ul>
      </section>
      <section className="card">
        <div className="form two">
          <label>Engine rpm<input className="input" inputMode="numeric" value={rpm} onChange={(e) => setRpm(e.target.value)} /></label>
          <label>Road speed (mph)<input className="input" inputMode="decimal" value={mph} onChange={(e) => setMph(e.target.value)} /></label>
          <label>Final drive ratio<input className="input" inputMode="decimal" value={fd} onChange={(e) => setFd(e.target.value)} /></label>
          <label>Tire size (e.g. 315/30R20)<input className="input mono" value={tire} onChange={(e) => setTire(e.target.value)} /></label>
        </div>
        {!t && <p className="err" role="alert">Enter a tire size like 315/30R20.</p>}
        {dia && <p className="muted">Tire diameter ≈ {dia.toFixed(2)} in{custom && <> · <button className="link-btn" onClick={() => { setFd(String(GT500_FINAL)); setTire(GT500_REAR_TIRE); }}>Reset to stock</button></>}</p>}
      </section>
      {dia && f && (
        <section className="card">
          <h2>Per gear</h2>
          <table className="tbl">
            <thead><tr><th>Gear</th><th>Ratio</th><th>mph @ {r ? r.toLocaleString('en-US') : '—'} rpm</th><th>rpm @ {m ?? '—'} mph</th></tr></thead>
            <tbody>
              {GT500_RATIOS.map((g, i) => {
                const s = r ? mphAt(r, g, f, dia) : null;
                const e = m ? rpmAt(m, g, f, dia) : null;
                return (
                  <tr key={i}>
                    <td>{i + 1}</td><td>{g.toFixed(2)}</td>
                    <td>{s === null ? '—' : s.toFixed(1)}{s !== null && s > limit && <span className="tag">limited</span>}</td>
                    <td>{e === null ? '—' : Math.round(e).toLocaleString('en-US')}{e !== null && e > GT500_REDLINE && <span className="tag tag-mod">over redline</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <Note>Top speed is electronically limited to about {limit} mph <Cite c={TOP_SPEED_SPEC.confidence} url={TOP_SPEED_SPEC.source} />. Theoretical figures above that are not reachable on a stock car.</Note>
        </section>
      )}
    </>
  );
}
