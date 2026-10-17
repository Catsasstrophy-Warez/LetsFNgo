import { useState } from 'react';
import { UnitInput } from '../components/UnitInput';
import { useT, useUnits } from '../components/SettingsContext';
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
  const t = useT();
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
      <h1>{t('nav.tools')}</h1>
      <p className="lede">{t('pt.lede')}</p>
      <section className="card">
        <div className="form two">
          <label>{t('pt.hp')}<input className="input" inputMode="numeric" value={hp} onChange={(e) => setHp(e.target.value)} /></label>
          <UnitInput label={t('pt.weight')} kind="weight" value={wtN} onChange={setWt} digits={0} />
          <UnitInput label={t('pt.extra')} kind="weight" value={driverN} onChange={setDriver} digits={0} />
        </div>
        <p className="muted">{t('pt.stock', { hp: String(hpSpec.value) })} <Cite c={hpSpec.confidence} url={hpSpec.source} /> · {t('pt.curb', { w: (() => { const c = convertSpec(wtSpec.value!, wtSpec.unit, u); return fmt(c.value, c.unit); })() })} <Cite c={wtSpec.confidence} url={wtSpec.source} /></p>
      </section>
      <section className="card">
        <h2>{t('pt.quarter')} <span className="badge badge-unverified">{t('pt.estimate')}</span></h2>
        {h && f ? (
          <table className="tbl">
            <thead><tr><th>{t('pt.formula')}</th><th>ET</th><th>{t('pt.trap')}</th></tr></thead>
            <tbody>
              <tr><td>Hale (5.825·∛(W/hp), 234·∛(hp/W))</td><td>{h.et.toFixed(2)} s</td><td>{fmtQty('speed', h.mph, u, 1)}</td></tr>
              <tr><td>Fox (6.290·∛(W/hp), 224·∛(hp/W))</td><td>{f.et.toFixed(2)} s</td><td>{fmtQty('speed', f.mph, u, 1)}</td></tr>
            </tbody>
          </table>
        ) : <p className="err">{t('pt.err')}</p>}
        <p className="muted">{t('pt.race', { w: fmtQty('weight', race, u) })}</p>
        <Note>{t('pt.note', { r: best.result })} <Cite c={best.confidence} url={best.source} />.</Note>
      </section>
      <section className="card">
        <h2>{t('pt.ptw')}</h2>
        {p ? (
          <dl className="facts">
            <div className="fact"><dt>{t('pt.lbhp')}</dt><dd className="val">{p.lbPerHp.toFixed(2)}</dd></div>
            <div className="fact"><dt>{t('pt.hpton')}</dt><dd className="val">{p.hpPerTon.toFixed(0)}</dd></div>
            <div className="fact"><dt>{t('pt.kgkw')}</dt><dd className="val">{p.kgPerKw.toFixed(2)}</dd></div>
            <div className="fact"><dt>{t('pt.wkg')}</dt><dd className="val">{p.wPerKg.toFixed(0)}</dd></div>
          </dl>
        ) : <p className="err">{t('pt.err')}</p>}
        <Note>{t('pt.noDriver')}</Note>
      </section>
    </>
  );
}
