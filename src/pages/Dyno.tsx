import { useEffect, useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { DynoChart } from '../components/DynoChart';
import { useUnits } from '../components/SettingsContext';
import { save } from '../lib/storage';
import { loadGarage, today, uid } from '../lib/garage';
import { CORRECTIONS, DYNO_KEY, DYNO_TYPES, airOf, convertCorrection, loadDyno, parseCurve, peaks, saeFactor, stdFactor, type Correction, type DynoPull, type DynoType } from '../lib/dyno';
import { fmtQty } from '../lib/units';
import { dynoBaselines, DYNO_CAVEAT } from '../data/dyno';

const CORR = Object.fromEntries(CORRECTIONS) as Record<Correction, string>;
const TYPE = Object.fromEntries(DYNO_TYPES) as Record<DynoType, string>;
const blankW = (): DynoPull['weather'] => ({ tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false });

export default function Dyno() {
  const u = useUnits();
  const [pulls, setPulls] = useState<DynoPull[]>(loadDyno);
  const [f, setF] = useState({ date: today(), shop: '', whp: null as number | null, wtq: null as number | null, dynoType: 'dynojet' as DynoType, correction: 'sae' as Correction, weather: blankW(), curveText: '', notes: '' });
  const [err, setErr] = useState('');
  const [sel, setSel] = useState<string[]>(() => loadDyno().filter((p) => p.curve.length >= 2).sort((a, b) => a.date.localeCompare(b.date)).slice(-3).map((p) => p.id));
  const [view, setView] = useState<Correction | 'as-logged'>('as-logged');
  useEffect(() => { save(DYNO_KEY, pulls); }, [pulls]);
  const mods = loadGarage().mods.map((m) => m.title);
  const setW = (k: keyof DynoPull['weather']) => (v: number | null) => setF({ ...f, weather: { ...f.weather, [k]: v } });
  const air = airOf(f.weather);
  const sorted = [...pulls].sort((a, b) => a.date.localeCompare(b.date));
  const label = (p: DynoPull) => `${p.date}${p.shop ? ` ${p.shop}` : ''} (${CORR[p.correction]})`;

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (f.whp === null || !(f.whp > 0) || f.whp > 5000) return setErr('Enter peak wheel horsepower (1–5,000).');
    if (f.wtq !== null && (f.wtq < 0 || f.wtq > 5000)) return setErr('Wheel torque must be 0–5,000 lb-ft.');
    if (f.weather.humidity !== null && (f.weather.humidity < 0 || f.weather.humidity > 100)) return setErr('Humidity must be 0–100%.');
    if (f.weather.pressureInHg !== null && (f.weather.pressureInHg < 1 || f.weather.pressureInHg > 40)) return setErr('Pressure looks wrong (expected about 20–32 inHg / 680–1,080 hPa).');
    const c = f.curveText.trim() ? parseCurve(f.curveText) : { ok: true as const, points: [] };
    if (!c.ok) return setErr(`Curve: ${c.error}`);
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
    return c === null ? 'needs weather' : c.toFixed(0);
  };

  return (
    <>
      <h1>Dyno Log</h1>
      <p className="lede">Log wheel horsepower and torque with dyno type, correction standard and weather. Your Garage mods are saved with each pull. Different dynos read differently — compare pulls from the same dyno.</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>New pull</h2>
        <div className="form two">
          <label>Date<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>Shop / dyno<input className="input" value={f.shop} maxLength={80} onChange={(e) => setF({ ...f, shop: e.target.value })} placeholder="e.g. Local tuner" /></label>
          <UnitInput label="Peak whp" kind={null} value={f.whp} onChange={(whp) => setF({ ...f, whp })} digits={1} />
          <UnitInput label="Peak wheel torque" kind="torque" value={f.wtq} onChange={(wtq) => setF({ ...f, wtq })} digits={1} />
          <label>Dyno type<select className="input" value={f.dynoType} onChange={(e) => setF({ ...f, dynoType: e.target.value as DynoType })}>{DYNO_TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
          <label>Correction<select className="input" value={f.correction} onChange={(e) => setF({ ...f, correction: e.target.value as Correction })}>{CORRECTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
        </div>
        <fieldset className="pressures wide">
          <legend>Weather (needed to convert between SAE and STD)</legend>
          <UnitInput label="Temp" kind="temp" value={f.weather.tempF} onChange={setW('tempF')} digits={1} />
          <UnitInput label="Baro" kind="pressure" value={f.weather.pressureInHg} onChange={setW('pressureInHg')} digits={2} />
          <UnitInput label="RH %" kind={null} value={f.weather.humidity} onChange={setW('humidity')} digits={0} />
          <UnitInput label="Elev." kind="altitude" value={f.weather.elevationFt} onChange={setW('elevationFt')} digits={0} />
        </fieldset>
        <label className="check"><input type="checkbox" checked={f.weather.pressureIsStation} onChange={(e) => setF({ ...f, weather: { ...f.weather, pressureIsStation: e.target.checked } })} /><span>Pressure is uncorrected station pressure (dyno weather station)</span></label>
        {air && <p className="muted small">Factors for this weather: SAE {saeFactor(air)?.toFixed(3) ?? '—'} · STD {stdFactor(air)?.toFixed(3) ?? '—'}</p>}
        <label>Curve points (optional): one "rpm, hp, tq" per line, "-" for blank
          <textarea className="input mono" rows={4} value={f.curveText} onChange={(e) => setF({ ...f, curveText: e.target.value })} placeholder={'3000, 280, 490\n5000, 520, 546\n7000, 690, 518'} /></label>
        <p className="muted small">Mods snapshot: {mods.length ? mods.join(', ') : 'stock (no mods in Garage)'}</p>
        <label>Notes<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">Save pull</button>
      </form>

      <SaeStdConverter />

      <section className="card">
        <h2>Overlay</h2>
        {sorted.some((p) => p.curve.length >= 2) ? (
          <fieldset className="plain"><legend className="small muted">Pulls to overlay (up to 5)</legend>
            {sorted.filter((p) => p.curve.length >= 2).map((p) => (
              <label className="check" key={p.id}><input type="checkbox" checked={sel.includes(p.id)} onChange={() => setSel((s) => (s.includes(p.id) ? s.filter((x) => x !== p.id) : [...s, p.id].slice(-5)))} /><span>{label(p)}</span></label>
            ))}
          </fieldset>
        ) : null}
        <DynoChart pulls={sorted.filter((p) => sel.includes(p.id))} label={label} />
        <Note>Curves are plotted as logged; mixed corrections are not converted on the chart.</Note>
      </section>

      <section className="card">
        <h2>Pulls</h2>
        <label className="form-label">Show figures as
          <select className="input" value={view} onChange={(e) => setView(e.target.value as typeof view)}>
            <option value="as-logged">As logged</option>{CORRECTIONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select></label>
        {sorted.length === 0 ? <p className="muted">No pulls logged yet.</p> : (
          <ul className="rows">
            {[...sorted].reverse().map((p) => {
              const pk = peaks(p);
              return (
                <li key={p.id}>
                  <div className="row-main"><strong>{shown(p, pk.hp)} whp{pk.tq !== null && <> · {view === 'as-logged' ? fmtQty('torque', pk.tq, u) : `${shown(p, pk.tq)} lb-ft`}</>}</strong>
                    <button className="link-btn danger" onClick={() => { if (confirm('Delete this pull?')) { setPulls(pulls.filter((x) => x.id !== p.id)); setSel((s) => s.filter((x) => x !== p.id)); } }} aria-label={`Delete pull ${p.date}`}>Delete</button></div>
                  <div className="row-meta"><span>{p.date}</span>{p.shop && <span>{p.shop}</span>}<span className="tag">{TYPE[p.dynoType]}</span><span className="tag">{CORR[p.correction]}</span>{p.curve.length > 0 && <span className="small muted">{p.curve.length} curve points</span>}</div>
                  {p.weather.tempF !== null && <p className="muted small">{fmtQty('temp', p.weather.tempF, u, 0)} · {fmtQty('pressure', p.weather.pressureInHg, u, 2)}{p.weather.humidity !== null && ` · ${p.weather.humidity}% RH`}</p>}
                  <p className="muted small">Mods: {p.mods.length ? p.mods.join(', ') : 'stock'}</p>
                  {p.notes && <p className="wrap">{p.notes}</p>}
                </li>
              );
            })}
          </ul>
        )}
      </section>

      <section className="card">
        <h2>Sourced stock baselines</h2>
        {dynoBaselines.length === 0 ? <p className="muted">No sourced stock baselines yet.</p> : (
          <ul className="rows">{dynoBaselines.map((b) => (
            <li key={b.id}><strong>{b.whp} whp{b.wtq !== null && ` / ${b.wtq} lb-ft`}</strong> — {b.label} <span className="tag">{b.dyno === 'other' ? 'dyno not stated' : TYPE[b.dyno]}</span> <Cite c={b.confidence} url={b.source} />{b.context && <div className="small">{b.context}</div>}{b.note && <div className="small muted">{b.note}</div>}</li>
          ))}</ul>
        )}
        <Note>{DYNO_CAVEAT}</Note>
      </section>
      <p className="muted small">Mods and costs live in the <Link to="/garage">Garage</Link>; compare gains per dollar in the <Link to="/planner">Build Planner</Link>.</p>
    </>
  );
}

export function SaeStdConverter() {
  const u = useUnits();
  const [v, setV] = useState<number | null>(700);
  const [from, setFrom] = useState<Correction>('sae');
  const [w, setW] = useState<DynoPull['weather']>({ tempF: 77, pressureInHg: 29.23, humidity: 0, elevationFt: 0, pressureIsStation: true });
  const air = airOf(w);
  const out = (to: Correction) => (v === null ? null : convertCorrection(v, from, to, air));
  return (
    <section className="card" aria-labelledby="conv-h">
      <h2 id="conv-h">SAE ↔ STD converter</h2>
      <div className="form two">
        <UnitInput label="Figure (hp or lb-ft)" kind={null} value={v} onChange={setV} digits={1} />
        <label>Logged as<select className="input" value={from} onChange={(e) => setFrom(e.target.value as Correction)}>{CORRECTIONS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <UnitInput label="Temp" kind="temp" value={w.tempF} onChange={(tempF) => setW({ ...w, tempF })} digits={1} />
        <UnitInput label={w.pressureIsStation ? 'Station pressure' : 'Barometer (corrected)'} kind="pressure" value={w.pressureInHg} onChange={(pressureInHg) => setW({ ...w, pressureInHg })} digits={2} />
        <UnitInput label="Humidity (%)" kind={null} value={w.humidity} onChange={(humidity) => setW({ ...w, humidity })} digits={0} />
        <UnitInput label="Elevation" kind="altitude" value={w.elevationFt} onChange={(elevationFt) => setW({ ...w, elevationFt })} digits={0} />
      </div>
      <label className="check"><input type="checkbox" checked={w.pressureIsStation} onChange={(e) => setW({ ...w, pressureIsStation: e.target.checked })} /><span>Pressure is uncorrected station pressure</span></label>
      {air && v !== null && out('sae') !== null ? (
        <p className="verdict ok" role="status">{CORRECTIONS.map(([k, l]) => `${l}: ${out(k)!.toFixed(1)}`).join(' · ')}{u === 'metric' ? '' : ''}</p>
      ) : <p className="err">Enter a figure, temperature and pressure (humidity 0–100%).</p>}
      <Note>SAE J1349: CF = 1.18 × (990 / Pd hPa) × √((T °C + 273) / 298) − 0.18. STD (J607): CF = (29.92 / Pd inHg) × √((T °F + 460) / 520). Pd is dry-air station pressure (vapor pressure removed). STD reads about 4% higher than SAE in typical weather.</Note>
    </section>
  );
}
