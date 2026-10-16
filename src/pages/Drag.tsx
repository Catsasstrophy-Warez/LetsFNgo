import { useState } from 'react';
import { useCarLog } from '../components/CarContext';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { EtTrend } from '../components/Trends';
import { useT, useUnits } from '../components/SettingsContext';
import { loadGarage, today, uid } from '../lib/garage';
import { DRAG_KEY, correctToSeaLevel, densityAltitude, dragStats, loadDrag, stockPasses, type Timeslip } from '../lib/drag';
import { fmtQty } from '../lib/units';

const blank = (): Omit<Timeslip, 'id' | 'mods'> => ({
  date: today(), track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null,
  weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false }, notes: '',
});
const s3 = (v: number | null) => (v === null ? '—' : v.toFixed(3));
const s2 = (v: number | null) => (v === null ? '—' : v.toFixed(2));

/** Calculated DA for the form's weather, or null if incomplete. */
function weatherDa(w: Timeslip['weather']) {
  const { tempF, pressureInHg, humidity, elevationFt } = w;
  if (tempF === null || pressureInHg === null) return null;
  return densityAltitude({ tempF, pressureInHg, humidity: humidity ?? 0, elevationFt: elevationFt ?? 0, pressureIsStation: w.pressureIsStation });
}

export function DaCalculator() {
  const u = useUnits();
  const t = useT();
  const [w, setW] = useState<Timeslip['weather']>({ tempF: 59, pressureInHg: 29.92, humidity: 0, elevationFt: 0, pressureIsStation: false });
  const r = weatherDa(w);
  return (
    <section className="card" aria-labelledby="da-h">
      <h2 id="da-h">{t('drag.da')}</h2>
      <div className="form two">
        <UnitInput label={t('drag.airTemp')} kind="temp" value={w.tempF} onChange={(tempF) => setW({ ...w, tempF })} digits={1} />
        <UnitInput label={w.pressureIsStation ? t('drag.station') : t('drag.baro')} kind="pressure" value={w.pressureInHg} onChange={(pressureInHg) => setW({ ...w, pressureInHg })} digits={2} />
        <UnitInput label={t('drag.humidity')} kind={null} value={w.humidity} onChange={(humidity) => setW({ ...w, humidity })} digits={0} />
        <UnitInput label={t('drag.elev')} kind="altitude" value={w.elevationFt} onChange={(elevationFt) => setW({ ...w, elevationFt })} digits={0} />
      </div>
      <label className="check"><input type="checkbox" checked={w.pressureIsStation} onChange={(e) => setW({ ...w, pressureIsStation: e.target.checked })} />
        <span>{t('drag.stationNote')}</span></label>
      {r ? (
        <p className="verdict ok" role="status">{t('drag.daResult', { da: fmtQty('altitude', r.daFt, u), p: (r.densityRatio * 100).toFixed(1) })}</p>
      ) : <p className="err">{t('drag.daErr')}</p>}
      <Note>{t('drag.daNote')}</Note>
    </section>
  );
}

export default function Drag() {
  const u = useUnits();
  const t = useT();
  const [slips, setSlips] = useCarLog<Timeslip>(DRAG_KEY, loadDrag);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  const mods = loadGarage().mods.map((m) => m.title);
  const calc = weatherDa(f.weather);
  const stats = dragStats(slips);
  const stock = stockPasses();
  const sorted = [...slips].sort((a, b) => a.date.localeCompare(b.date));
  const setN = (k: keyof Timeslip) => (v: number | null) => setF({ ...f, [k]: v });
  const setW = (k: keyof Timeslip['weather']) => (v: number | null) => setF({ ...f, weather: { ...f.weather, [k]: v } });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (f.quarterEt === null && f.eighthEt === null) return setErr(t('drag.errEt'));
    if (f.weather.humidity !== null && (f.weather.humidity < 0 || f.weather.humidity > 100)) return setErr(t('drag.errRh'));
    setErr('');
    setSlips([...slips, { id: uid(), ...f, da: f.da ?? (calc ? Math.round(calc.daFt) : null), mods }]);
    setF({ ...blank(), track: f.track, weather: f.weather });
  };

  return (
    <>
      <h1>{t('nav.drag')}</h1>
      <p className="lede">{t('drag.lede')} <Link to="/settings">{t('specs.settingLink')}</Link> · <Link to="/gps">{t('nav.gps')} →</Link></p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>{t('drag.new')}</h2>
        <div className="form two">
          <label>{t('log.date')}<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>{t('track.track')}<input className="input" value={f.track} onChange={(e) => setF({ ...f, track: e.target.value })} placeholder={t('drag.trackPh')} /></label>
        </div>
        <div className="form four">
          <UnitInput label={t('drag.rt')} kind={null} value={f.rt} onChange={setN('rt')} digits={3} />
          <UnitInput label={t('drag.sixty')} kind={null} value={f.sixty} onChange={setN('sixty')} digits={3} />
          <UnitInput label={t('drag.330')} kind={null} value={f.threeThirty} onChange={setN('threeThirty')} digits={3} />
          <UnitInput label={t('drag.eighthEt')} kind={null} value={f.eighthEt} onChange={setN('eighthEt')} digits={3} />
          <UnitInput label={t('drag.eighthMph')} kind="speed" value={f.eighthMph} onChange={setN('eighthMph')} digits={2} />
          <UnitInput label={t('drag.quarterEt')} kind={null} value={f.quarterEt} onChange={setN('quarterEt')} digits={3} />
          <UnitInput label={t('drag.quarterMph')} kind="speed" value={f.quarterMph} onChange={setN('quarterMph')} digits={2} />
          <UnitInput label={t('drag.daSlip')} kind="altitude" value={f.da} onChange={setN('da')} digits={0} hint={t('drag.optional')} />
        </div>
        <fieldset className="pressures wide">
          <legend>{t('drag.weather')}</legend>
          <UnitInput label={t('drag.temp')} kind="temp" value={f.weather.tempF} onChange={setW('tempF')} digits={1} />
          <UnitInput label={t('drag.baroShort')} kind="pressure" value={f.weather.pressureInHg} onChange={setW('pressureInHg')} digits={2} />
          <UnitInput label={t('drag.rh')} kind={null} value={f.weather.humidity} onChange={setW('humidity')} digits={0} />
          <UnitInput label={t('drag.elevShort')} kind="altitude" value={f.weather.elevationFt} onChange={setW('elevationFt')} digits={0} />
        </fieldset>
        {calc && f.da === null && <p className="muted">{t('drag.calcDa', { d: fmtQty('altitude', calc.daFt, u) })}</p>}
        <p className="muted small">{t('drag.modsSnap', { m: mods.length ? mods.join(', ') : t('drag.stockNoMods') })}</p>
        <label>{t('log.notes')}<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">{t('drag.save')}</button>
      </form>

      <section className="card">
        <h2>{t('drag.bestTitle')}</h2>
        <div className="stats">
          <div className="stat"><div className="stat-v">{s3(stats.bestEt)}</div><div className="stat-l">{t('drag.bestEt')}</div></div>
          <div className="stat"><div className="stat-v">{stats.bestMph === null ? '—' : fmtQty('speed', stats.bestMph, u, 1)}</div><div className="stat-l">{t('drag.bestMph')}</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.bestSixty)}</div><div className="stat-l">{t('drag.bestSixty')}</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.bestRt)}</div><div className="stat-l">{t('drag.bestRt')}</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.meanEt)}</div><div className="stat-l">{t('drag.meanEt')}</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.sdEt)}</div><div className="stat-l">{t('drag.sd')}</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.spreadEt)}</div><div className="stat-l">{t('drag.spread')}</div></div>
          <div className="stat"><div className="stat-v">{stats.count}</div><div className="stat-l">{t('drag.passes')}</div></div>
        </div>
        <EtTrend slips={sorted} />
      </section>

      <section className="card">
        <h2>{t('drag.stock')}</h2>
        <ul className="rows">
          {stock.map((p) => (
            <li key={p.record.id}><strong>{p.et.toFixed(2)} s{p.mph !== null && ` @ ${fmtQty('speed', p.mph, u)}`}</strong> — {p.record.label} <span className="tag">{p.record.car}</span>
              {stats.bestEt !== null && <span className="muted"> · {t('track.yourBest')} {stats.bestEt - p.et <= 0 ? '−' : '+'}{Math.abs(stats.bestEt - p.et).toFixed(2)} s</span>} <Cite c={p.record.confidence} url={p.record.source} /></li>
          ))}
        </ul>
        <Note>{t('drag.stockNote')}</Note>
      </section>

      <DaCalculator />

      {sorted.length === 0 ? <p className="muted">{t('drag.empty')}</p> : [...sorted].reverse().map((s) => {
        const corr = s.quarterEt !== null && s.da !== null ? correctToSeaLevel(s.quarterEt, s.quarterMph, s.da) : null;
        if (s.gps) return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{t(`drag.gps.${s.gps.kind}`)} <span className="badge badge-unverified">{t('drag.gpsEstimate')}</span> <span className="muted small">{s.date}</span></h2>
              <button className="link-btn danger" onClick={() => { if (confirm(t('drag.confirmGps'))) setSlips(slips.filter((x) => x.id !== s.id)); }} aria-label={t('drag.deleteGps', { d: s.date })}>{t('common.delete')}</button></div>
            <p><strong>{s.gps.seconds.toFixed(2)} s</strong>{s.gps.trapMph !== null && <> @ {fmtQty('speed', s.gps.trapMph, u, 1)}</>} <span className="muted">· {t('drag.gpsNote', { m: s.gps.accuracyM })}</span></p>
            <p className="muted small">{t('drag.mods', { m: s.mods.length ? s.mods.join(', ') : t('drag.stockWord') })}</p>
          </section>
        );
        return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{s.track || t('drag.strip')} <span className="muted small">{s.date}</span></h2>
              <button className="link-btn danger" onClick={() => { if (confirm(t('drag.confirmSlip'))) setSlips(slips.filter((x) => x.id !== s.id)); }} aria-label={t('drag.deleteSlip', { d: s.date })}>{t('common.delete')}</button></div>
            <table className="tbl slip">
              <tbody>
                <tr><th>R/T</th><td>{s3(s.rt)}</td><th>60 ft</th><td>{s3(s.sixty)}</td></tr>
                <tr><th>330 ft</th><td>{s3(s.threeThirty)}</td><th>DA</th><td>{fmtQty('altitude', s.da, u)}</td></tr>
                <tr><th>⅛ ET</th><td>{s3(s.eighthEt)}</td><th>⅛ speed</th><td>{fmtQty('speed', s.eighthMph, u, 2)}</td></tr>
                <tr><th>¼ ET</th><td><strong>{s3(s.quarterEt)}</strong></td><th>¼ speed</th><td><strong>{fmtQty('speed', s.quarterMph, u, 2)}</strong></td></tr>
              </tbody>
            </table>
            {corr && (
              <p className="muted">{t('drag.corrected')} <span className="badge badge-unverified">{t('drag.estimate')}</span>: {t('drag.correctedText', { et: s2(corr.et), mph: corr.mph !== null ? ` @ ${fmtQty('speed', corr.mph, u, 1)}` : '' })}</p>
            )}
            <p className="muted small">{t('drag.mods', { m: s.mods.length ? s.mods.join(', ') : t('drag.stockWord') })}</p>
            {s.notes && <p className="wrap">{s.notes}</p>}
          </section>
        );
      })}
    </>
  );
}
