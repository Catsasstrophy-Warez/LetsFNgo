import { useState } from 'react';
import { useT, useUnits } from '../components/SettingsContext';
import { fromDisplay, toDisplay, unitLabel } from '../lib/units';
import { Cite, Note } from '../components/Facts';
import {
  DIFF_SPEC, GT500_FINAL, GT500_RATIOS, GT500_REAR_TIRE, GT500_REDLINE, RATIO_SPEC, REDLINE_SPEC, TIRE_SPECS, TOP_SPEED_SPEC,
  mphAt, parseTireSize, rpmAt, tireDiameterIn,
} from '../lib/gearing';

const num = (s: string) => { const n = Number(s); return Number.isFinite(n) && n > 0 ? n : null; };

export default function Gearing() {
  const u = useUnits();
  const tt = useT();
  const sp = unitLabel('speed', u);
  const [rpm, setRpm] = useState(String(GT500_REDLINE));
  const [mph, setMph] = useState('60');
  const [fd, setFd] = useState(String(GT500_FINAL));
  const [tire, setTire] = useState(GT500_REAR_TIRE);
  const t = parseTireSize(tire);
  const dia = t ? tireDiameterIn(t) : null;
  const r = num(rpm), mDisp = num(mph), f = num(fd);
  const m = mDisp === null ? null : fromDisplay('speed', mDisp, u);
  const limit = Number(TOP_SPEED_SPEC.value);
  const custom = f !== GT500_FINAL || tire.replace(/\s/g, '').toUpperCase() !== GT500_REAR_TIRE;

  return (
    <>
      <h1>{tt('gear.title')}</h1>
      <p className="lede">{tt('gear.lede')}</p>
      <section className="card">
        <ul className="rows">
          <li>{tt('gear.ratios')} {GT500_RATIOS.join(' / ')} <Cite c={RATIO_SPEC.confidence} url={RATIO_SPEC.source} /></li>
          <li>{tt('gear.final')} {GT500_FINAL}:1 <Cite c={DIFF_SPEC.confidence} url={DIFF_SPEC.source} /></li>
          <li>{tt('gear.redline')} {GT500_REDLINE.toLocaleString('en-US')} rpm <Cite c={REDLINE_SPEC.confidence} url={REDLINE_SPEC.source} /></li>
          {TIRE_SPECS.map((s) => <li key={s.id}>{s.label} {String(s.value)} <Cite c={s.confidence} url={s.source} />{s.id === 'tire-r' && <Note>{tt('gear.rearNote')}</Note>}</li>)}
        </ul>
      </section>
      <section className="card">
        <div className="form two">
          <label>{tt('gear.rpm')}<input className="input" inputMode="numeric" value={rpm} onChange={(e) => setRpm(e.target.value)} /></label>
          <label>{tt('gear.speed', { u: sp })}<input className="input" inputMode="decimal" value={mph} onChange={(e) => setMph(e.target.value)} /></label>
          <label>{tt('gear.fd')}<input className="input" inputMode="decimal" value={fd} onChange={(e) => setFd(e.target.value)} /></label>
          <label>{tt('gear.tire')}<input className="input mono" value={tire} onChange={(e) => setTire(e.target.value)} /></label>
        </div>
        {!t && <p className="err" role="alert">{tt('gear.tireErr')}</p>}
        {dia && <p className="muted">{tt('gear.dia', { d: u === 'metric' ? `${(dia * 25.4).toFixed(0)} mm` : `${dia.toFixed(2)} in` })}{custom && <> · <button className="link-btn" onClick={() => { setFd(String(GT500_FINAL)); setTire(GT500_REAR_TIRE); }}>{tt('gear.reset')}</button></>}</p>}
      </section>
      {dia && f && (
        <section className="card">
          <h2>{tt('gear.per')}</h2>
          <table className="tbl">
            <thead><tr><th>{tt('tires.gear')}</th><th>{tt('gear.ratio')}</th><th>{sp} @ {r ? r.toLocaleString('en-US') : '—'} rpm</th><th>rpm @ {mDisp ?? '—'} {sp}</th></tr></thead>
            <tbody>
              {GT500_RATIOS.map((g, i) => {
                const s = r ? mphAt(r, g, f, dia) : null;
                const e = m ? rpmAt(m, g, f, dia) : null;
                return (
                  <tr key={i}>
                    <td>{i + 1}</td><td>{g.toFixed(2)}</td>
                    <td>{s === null ? '—' : toDisplay('speed', s, u).toFixed(1)}{s !== null && s > limit && <span className="tag">{tt('gear.limited')}</span>}</td>
                    <td>{e === null ? '—' : Math.round(e).toLocaleString('en-US')}{e !== null && e > GT500_REDLINE && <span className="tag tag-mod">{tt('gear.over')}</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <Note>{tt('gear.note', { v: Math.round(toDisplay('speed', limit, u)), u: sp })} <Cite c={TOP_SPEED_SPEC.confidence} url={TOP_SPEED_SPEC.source} /></Note>
        </section>
      )}
    </>
  );
}
