import { useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { useT, useUnits } from '../components/SettingsContext';
import { GT500_FINAL, GT500_RATIOS, GT500_REAR_TIRE, GT500_REDLINE, TIRE_SPECS } from '../lib/gearing';
import { compareTires } from '../lib/tires';
import { fmtQty } from '../lib/units';

const pct = (n: number) => `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(2)}%`;

export default function Tires() {
  const u = useUnits();
  const t = useT();
  const [stock, setStock] = useState(GT500_REAR_TIRE);
  const [alt, setAlt] = useState('315/35R20');
  const [gear, setGear] = useState(6);
  const c = compareTires(stock, alt, GT500_RATIOS, GT500_FINAL, GT500_REDLINE);
  const len = (inches: number) => fmtQty('length', inches, u, u === 'metric' ? 0 : 2);
  const rows = c ? [
    [t('tires.dia'), len(c.stock.diameterIn), len(c.alt.diameterIn)],
    [t('tires.sidewall'), len(c.stock.sidewallIn), len(c.alt.sidewallIn)],
    [t('tires.width'), len(c.stock.widthIn), len(c.alt.widthIn)],
    [t('tires.circ'), len(c.stock.circumferenceIn), len(c.alt.circumferenceIn)],
    [u === 'metric' ? t('tires.revsKm') : t('tires.revsMi'), (u === 'metric' ? c.stock.revsPerMile / 1.609344 : c.stock.revsPerMile).toFixed(0), (u === 'metric' ? c.alt.revsPerMile / 1.609344 : c.alt.revsPerMile).toFixed(0)],
  ] : [];
  return (
    <>
      <h1>{t('tires.title')}</h1>
      <p className="lede">{t('tires.lede', { d: u === 'metric' ? t('tires.km') : t('tires.mile'), fd: GT500_FINAL })}</p>
      <section className="card">
        <div className="form two">
          <label>{t('tires.stock')}<input className="input mono" value={stock} onChange={(e) => setStock(e.target.value)} /></label>
          <label>{t('tires.alt')}<input className="input mono" value={alt} onChange={(e) => setAlt(e.target.value)} /></label>
        </div>
        <ul className="rows small">{TIRE_SPECS.map((s) => <li key={s.id}>{s.label}: {String(s.value)} <Cite c={s.confidence} url={s.source} /></li>)}</ul>
      </section>
      {!c ? <p className="err" role="alert">{t('tires.err')}</p> : (
        <>
          <section className="card hl" aria-live="polite">
            <h2>{t('tires.result')}</h2>
            <p className="stat-v">{pct(c.diameterPct)}<small>{t('tires.diameter')}</small></p>
            <p>{t('tires.speedo', { a: fmtQty('speed', 60, u), b: fmtQty('speed', c.actualAt(60), u, 1), dir: c.speedoErrorPct >= 0 ? t('tires.low') : t('tires.high'), p: Math.abs(c.speedoErrorPct).toFixed(1) })}</p>
            <p>{t('tires.fd', { e: c.effectiveFinal.toFixed(2), s: GT500_FINAL.toFixed(2) })}{c.diameterPct > 0 ? t('tires.taller') : c.diameterPct < 0 ? t('tires.shorter') : '.'}</p>
            {Math.abs(c.diameterPct) > 3 && <p className="warn-t">{t('tires.warn')}</p>}
          </section>
          <section className="card">
            <h2>{t('tires.sizes')}</h2>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('tires.cmp')}>
              <table className="tbl"><thead><tr><th scope="col">{t('tires.figure')}</th><th scope="col">{t('tires.stockCol')}</th><th scope="col">{t('tires.altCol')}</th></tr></thead>
                <tbody>{rows.map(([k, a, b]) => <tr key={k}><th scope="row">{k}</th><td>{a}</td><td>{b}</td></tr>)}</tbody></table>
            </div>
          </section>
          <section className="card">
            <h2>{t('tires.gearing')}</h2>
            <label className="form-label">{t('tires.gearFor')}
              <select className="input" value={gear} onChange={(e) => setGear(Number(e.target.value))}>{GT500_RATIOS.map((g, i) => <option key={i} value={i + 1}>{i + 1} ({g.toFixed(2)})</option>)}</select></label>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('tires.rpmAt')}>
              <table className="tbl"><thead><tr><th scope="col">{t('tires.speed')}</th><th scope="col">{t('tires.stockRpm')}</th><th scope="col">{t('tires.altRpm')}</th></tr></thead>
                <tbody>{[40, 60, 70, 80].map((mph) => { const r = c.rpmAt(mph, GT500_RATIOS[gear - 1]); return <tr key={mph}><th scope="row">{fmtQty('speed', mph, u)}</th><td>{r.stock.toFixed(0)}</td><td>{r.alt.toFixed(0)}</td></tr>; })}</tbody></table>
            </div>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('tires.redline')}>
              <table className="tbl"><thead><tr><th scope="col">{t('tires.gear')}</th><th scope="col">{t('tires.stockAt', { r: GT500_REDLINE.toLocaleString('en-US') })}</th><th scope="col">{t('tires.altCol')}</th></tr></thead>
                <tbody>{c.topSpeedPerGear.map((g) => <tr key={g.gear}><th scope="row">{g.gear}</th><td>{fmtQty('speed', g.stock, u)}</td><td>{fmtQty('speed', g.alt, u)}</td></tr>)}</tbody></table>
            </div>
            <Note>{t('tires.note')} <Link to="/gearing">{t('nav.gearing')} →</Link></Note>
          </section>
        </>
      )}
    </>
  );
}
