import { useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { DynoChart } from '../components/DynoChart';
import { useT, useUnits } from '../components/SettingsContext';
import { tr } from '../lib/i18n';
import { activeCarId, forCar, loadGarage, today, uid } from '../lib/garage';
import { useCarLog } from '../components/CarContext';
import { CORRECTIONS, DYNO_KEY, DYNO_TYPES, airOf, convertCorrection, loadDyno, parseCurve, peaks, saeFactor, stdFactor, type Correction, type DynoPull, type DynoType } from '../lib/dyno';
import { fmtQty } from '../lib/units';
import { dynoBaselines, DYNO_CAVEAT } from '../data/dyno';

const CORR = (c: Correction) => tr(`dyno.corr.${c}`);
const TYPE = (d: DynoType) => tr(`dyno.type.${d}`);
const blankW = (): DynoPull['weather'] => ({ tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false });

export default function Dyno() {
  const u = useUnits();
  const t = useT();
  const [pulls, setPulls] = useCarLog<DynoPull>(DYNO_KEY, loadDyno);
  const [f, setF] = useState({ date: today(), shop: '', whp: null as number | null, wtq: null as number | null, dynoType: 'dynojet' as DynoType, correction: 'sae' as Correction, weather: blankW(), curveText: '', notes: '' });
  const [err, setErr] = useState('');
  const [sel, setSel] = useState<string[]>(() => forCar(loadDyno(), activeCarId()).filter((p) => p.curve.length >= 2).sort((a, b) => a.date.localeCompare(b.date)).slice(-3).map((p) => p.id));
  const [view, setView] = useState<Correction | 'as-logged'>('as-logged');
  const mods = loadGarage().mods.map((m) => m.title);
  const setW = (k: keyof DynoPull['weather']) => (v: number | null) => setF({ ...f, weather: { ...f.weather, [k]: v } });
  const air = airOf(f.weather);
  const sorted = [...pulls].sort((a, b) => a.date.localeCompare(b.date));
  const label = (p: DynoPull) => `${p.date}${p.shop ? ` ${p.shop}` : ''} (${CORR(p.correction)})`;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (f.whp === null || !(f.whp > 0) || f.whp > 5000) return setErr(t('dyno.errWhp'));
    if (f.wtq !== null && (f.wtq < 0 || f.wtq > 5000)) return setErr(t('dyno.errWtq'));
    if (f.weather.humidity !== null && (f.weather.humidity < 0 || f.weather.humidity > 100)) return setErr(t('drag.errRh'));
    if (f.weather.pressureInHg !== null && (f.weather.pressureInHg < 1 || f.weather.pressureInHg > 40)) return setErr(t('dyno.errP'));
    const c = f.curveText.trim() ? parseCurve(f.curveText) : { ok: true as const, points: [] };
    if (!c.ok) return setErr(t('dyno.errCurve', { e: c.error }));
    setErr('');
    const p: DynoPull = { id: uid(), date: f.date || today(), shop: f.shop.trim(), whp: f.whp, wtq: f.wtq, dynoType: f.dynoType, correction: f.correction, weather: f.weather, mods, curve: c.points, notes: f.notes };
    setPulls([...pulls, p]);
    setSel((s) => [...s, p.id].slice(-5));
    setF({ ...f, whp: null, wtq: null, curveText: '', notes: '' });
  };

  const shown = (p: DynoPull, v: number | null) => {
    if (v === null) return '—';
    if (view === 'as-logged') return `${v.toFixed(0)}`;
    const c = convertCorrection(v, p.correction, view, airOf(p.weather));
    return c === null ? t('dyno.needsWeather') : c.toFixed(0);
  };

  return (
    <>
      <h1>{t('nav.dyno')}</h1>
      <p className="lede">{t('dyno.lede')}</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>{t('dyno.new')}</h2>
        <div className="form two">
          <label>{t('log.date')}<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>{t('dyno.shop')}<input className="input" value={f.shop} maxLength={80} onChange={(e) => setF({ ...f, shop: e.target.value })} placeholder={t('dyno.shopPh')} /></label>
          <UnitInput label={t('dyno.whp')} kind={null} value={f.whp} onChange={(whp) => setF({ ...f, whp })} digits={1} />
          <UnitInput label={t('dyno.wtq')} kind="torque" value={f.wtq} onChange={(wtq) => setF({ ...f, wtq })} digits={1} />
          <label>{t('dyno.type')}<select className="input" value={f.dynoType} onChange={(e) => setF({ ...f, dynoType: e.target.value as DynoType })}>{DYNO_TYPES.map(([v]) => <option key={v} value={v}>{TYPE(v)}</option>)}</select></label>
          <label>{t('dyno.correction')}<select className="input" value={f.correction} onChange={(e) => setF({ ...f, correction: e.target.value as Correction })}>{CORRECTIONS.map(([v]) => <option key={v} value={v}>{CORR(v)}</option>)}</select></label>
        </div>
        <fieldset className="pressures wide">
          <legend>{t('dyno.weather')}</legend>
          <UnitInput label={t('drag.temp')} kind="temp" value={f.weather.tempF} onChange={setW('tempF')} digits={1} />
          <UnitInput label={t('drag.baroShort')} kind="pressure" value={f.weather.pressureInHg} onChange={setW('pressureInHg')} digits={2} />
          <UnitInput label={t('drag.rh')} kind={null} value={f.weather.humidity} onChange={setW('humidity')} digits={0} />
          <UnitInput label={t('drag.elevShort')} kind="altitude" value={f.weather.elevationFt} onChange={setW('elevationFt')} digits={0} />
        </fieldset>
        <label className="check"><input type="checkbox" checked={f.weather.pressureIsStation} onChange={(e) => setF({ ...f, weather: { ...f.weather, pressureIsStation: e.target.checked } })} /><span>{t('dyno.stationShort')}</span></label>
        {air && <p className="muted small">{t('dyno.factors', { sae: saeFactor(air)?.toFixed(3) ?? '—', std: stdFactor(air)?.toFixed(3) ?? '—' })}</p>}
        <label>{t('dyno.curve')}
          <textarea className="input mono" rows={4} value={f.curveText} onChange={(e) => setF({ ...f, curveText: e.target.value })} placeholder={'3000, 280, 490\n5000, 520, 546\n7000, 690, 518'} /></label>
        <p className="muted small">{t('drag.modsSnap', { m: mods.length ? mods.join(', ') : t('drag.stockNoMods') })}</p>
        <label>{t('log.notes')}<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">{t('dyno.save')}</button>
      </form>

      <SaeStdConverter />

      <section className="card">
        <h2>{t('dyno.overlay')}</h2>
        {sorted.some((p) => p.curve.length >= 2) ? (
          <fieldset className="plain"><legend className="small muted">{t('dyno.pick')}</legend>
            {sorted.filter((p) => p.curve.length >= 2).map((p) => (
              <label className="check" key={p.id}><input type="checkbox" checked={sel.includes(p.id)} onChange={() => setSel((s) => (s.includes(p.id) ? s.filter((x) => x !== p.id) : [...s, p.id].slice(-5)))} /><span>{label(p)}</span></label>
            ))}
          </fieldset>
        ) : null}
        <DynoChart pulls={sorted.filter((p) => sel.includes(p.id))} label={label} />
        <Note>{t('dyno.overlayNote')}</Note>
      </section>

      <section className="card">
        <h2>{t('dyno.pulls')}</h2>
        <label className="form-label">{t('dyno.showAs')}
          <select className="input" value={view} onChange={(e) => setView(e.target.value as typeof view)}>
            <option value="as-logged">{t('dyno.asLogged')}</option>{CORRECTIONS.map(([v]) => <option key={v} value={v}>{CORR(v)}</option>)}
          </select></label>
        {sorted.length === 0 ? <p className="muted">{t('dyno.empty')}</p> : (
          <ul className="rows">
            {[...sorted].reverse().map((p) => {
              const pk = peaks(p);
              return (
                <li key={p.id}>
                  <div className="row-main"><strong>{shown(p, pk.hp)} whp{pk.tq !== null && <> · {view === 'as-logged' ? fmtQty('torque', pk.tq, u) : `${shown(p, pk.tq)} lb-ft`}</>}</strong>
                    <button className="link-btn danger" onClick={() => { if (confirm(t('dyno.confirm'))) { setPulls(pulls.filter((x) => x.id !== p.id)); setSel((s) => s.filter((x) => x !== p.id)); } }} aria-label={t('dyno.delete', { d: p.date })}>{t('common.delete')}</button></div>
                  <div className="row-meta"><span>{p.date}</span>{p.shop && <span>{p.shop}</span>}<span className="tag">{TYPE(p.dynoType)}</span><span className="tag">{CORR(p.correction)}</span>{p.curve.length > 0 && <span className="small muted">{t('dyno.points', { n: p.curve.length })}</span>}</div>
                  {p.weather.tempF !== null && <p className="muted small">{fmtQty('temp', p.weather.tempF, u, 0)} · {fmtQty('pressure', p.weather.pressureInHg, u, 2)}{p.weather.humidity !== null && ` · ${p.weather.humidity}% RH`}</p>}
                  <p className="muted small">{t('drag.mods', { m: p.mods.length ? p.mods.join(', ') : t('drag.stockWord') })}</p>
                  {p.notes && <p className="wrap">{p.notes}</p>}
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="card">
        <h2>{t('dyno.baselines')}</h2>
        {dynoBaselines.length === 0 ? <p className="muted">{t('dyno.noBaselines')}</p> : (
          <ul className="rows">{dynoBaselines.map((b) => (
            <li key={b.id}><strong>{b.whp} whp{b.wtq !== null && ` / ${b.wtq} lb-ft`}</strong> — {b.label} <span className="tag">{b.dyno === 'other' ? t('dyno.notStated') : TYPE(b.dyno)}</span> <Cite c={b.confidence} url={b.source} />{b.context && <div className="small">{b.context}</div>}{b.note && <div className="small muted">{b.note}</div>}</li>
          ))}</ul>
        )}
        <Note>{DYNO_CAVEAT}</Note>
      </section>
      <p className="muted small">{t('dyno.footer')} <Link to="/garage">{t('nav.garage')} →</Link> · <Link to="/planner">{t('nav.planner')} →</Link></p>
    </>
  );
}

export function SaeStdConverter() {
  const u = useUnits();
  const t = useT();
  const [v, setV] = useState<number | null>(700);
  const [from, setFrom] = useState<Correction>('sae');
  const [w, setW] = useState<DynoPull['weather']>({ tempF: 77, pressureInHg: 29.23, humidity: 0, elevationFt: 0, pressureIsStation: true });
  const air = airOf(w);
  const out = (to: Correction) => (v === null ? null : convertCorrection(v, from, to, air));
  return (
    <section className="card" aria-labelledby="conv-h">
      <h2 id="conv-h">{t('dyno.conv')}</h2>
      <div className="form two">
        <UnitInput label={t('dyno.figure')} kind={null} value={v} onChange={setV} digits={1} />
        <label>{t('dyno.loggedAs')}<select className="input" value={from} onChange={(e) => setFrom(e.target.value as Correction)}>{CORRECTIONS.map(([k]) => <option key={k} value={k}>{CORR(k)}</option>)}</select></label>
        <UnitInput label={t('drag.temp')} kind="temp" value={w.tempF} onChange={(tempF) => setW({ ...w, tempF })} digits={1} />
        <UnitInput label={w.pressureIsStation ? t('drag.station') : t('drag.baro')} kind="pressure" value={w.pressureInHg} onChange={(pressureInHg) => setW({ ...w, pressureInHg })} digits={2} />
        <UnitInput label={t('drag.humidity')} kind={null} value={w.humidity} onChange={(humidity) => setW({ ...w, humidity })} digits={0} />
        <UnitInput label={t('dyno.elevation')} kind="altitude" value={w.elevationFt} onChange={(elevationFt) => setW({ ...w, elevationFt })} digits={0} />
      </div>
      <label className="check"><input type="checkbox" checked={w.pressureIsStation} onChange={(e) => setW({ ...w, pressureIsStation: e.target.checked })} /><span>{t('dyno.stationPlain')}</span></label>
      {air && v !== null && out('sae') !== null ? (
        <p className="verdict ok" role="status">{CORRECTIONS.map(([k]) => `${CORR(k)}: ${out(k)!.toFixed(1)}`).join(' · ')}{u === 'metric' ? '' : ''}</p>
      ) : <p className="err">{t('dyno.convErr')}</p>}
      <Note>{t('dyno.convNote')}</Note>
    </section>
  );
}
