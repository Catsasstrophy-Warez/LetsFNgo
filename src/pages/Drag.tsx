import { useEffect, useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { UnitInput } from '../components/UnitInput';
import { EtTrend } from '../components/Trends';
import { useUnits } from '../components/SettingsContext';
import { save } from '../lib/storage';
import { loadGarage, today, uid } from '../lib/garage';
import { DRAG_KEY, correctToSeaLevel, densityAltitude, dragStats, loadDrag, stockPasses, type Timeslip } from '../lib/drag';
import { fmtQty } from '../lib/units';

const blank = (): Omit<Timeslip, 'id' | 'mods'> => ({
  date: today(), track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null,
  weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false }, notes: '',
});
const GPS_LABEL = { '0-60': '0–60 mph', '60-130': '60–130 mph', quarter: '¼ mile' } as const;
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
  const [w, setW] = useState<Timeslip['weather']>({ tempF: 59, pressureInHg: 29.92, humidity: 0, elevationFt: 0, pressureIsStation: false });
  const r = weatherDa(w);
  return (
    <section className="card" aria-labelledby="da-h">
      <h2 id="da-h">Density altitude calculator</h2>
      <div className="form two">
        <UnitInput label="Air temp" kind="temp" value={w.tempF} onChange={(tempF) => setW({ ...w, tempF })} digits={1} />
        <UnitInput label={w.pressureIsStation ? 'Station pressure' : 'Barometer (corrected)'} kind="pressure" value={w.pressureInHg} onChange={(pressureInHg) => setW({ ...w, pressureInHg })} digits={2} />
        <UnitInput label="Humidity (%)" kind={null} value={w.humidity} onChange={(humidity) => setW({ ...w, humidity })} digits={0} />
        <UnitInput label="Track elevation" kind="altitude" value={w.elevationFt} onChange={(elevationFt) => setW({ ...w, elevationFt })} digits={0} />
      </div>
      <label className="check"><input type="checkbox" checked={w.pressureIsStation} onChange={(e) => setW({ ...w, pressureIsStation: e.target.checked })} />
        <span>Pressure is uncorrected station pressure (from a track weather station); elevation is then already included.</span></label>
      {r ? (
        <p className="verdict ok" role="status">DA {fmtQty('altitude', r.daFt, u)} · air density {(r.densityRatio * 100).toFixed(1)}% of standard</p>
      ) : <p className="err">Enter temperature and pressure (humidity 0–100%).</p>}
      <Note>Standard method: vapor pressure from humidity → virtual temperature → air density from station pressure → ISA altitude with that density. A corrected barometer (what weather apps show) is converted to station pressure using elevation.</Note>
    </section>
  );
}

export default function Drag() {
  const u = useUnits();
  const [slips, setSlips] = useState<Timeslip[]>(loadDrag);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  useEffect(() => { save(DRAG_KEY, slips); }, [slips]);
  const mods = loadGarage().mods.map((m) => m.title);
  const calc = weatherDa(f.weather);
  const stats = dragStats(slips);
  const stock = stockPasses();
  const sorted = [...slips].sort((a, b) => a.date.localeCompare(b.date));
  const setN = (k: keyof Timeslip) => (v: number | null) => setF({ ...f, [k]: v });
  const setW = (k: keyof Timeslip['weather']) => (v: number | null) => setF({ ...f, weather: { ...f.weather, [k]: v } });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (f.quarterEt === null && f.eighthEt === null) return setErr('Enter at least a ¼-mile or ⅛-mile ET.');
    if (f.weather.humidity !== null && (f.weather.humidity < 0 || f.weather.humidity > 100)) return setErr('Humidity must be 0–100%.');
    setErr('');
    setSlips([...slips, { id: uid(), ...f, da: f.da ?? (calc ? Math.round(calc.daFt) : null), mods }]);
    setF({ ...blank(), track: f.track, weather: f.weather });
  };

  return (
    <>
      <h1>Drag Strip Log</h1>
      <p className="lede">Log timeslips on this device. Times are seconds; speeds and weather follow your <Link to="/settings">units setting</Link>. Your Garage mods list is saved with each pass. Runs from the <Link to="/gps">GPS meter</Link> appear as "GPS estimate" and are kept out of the stats.</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>New timeslip</h2>
        <div className="form two">
          <label>Date<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>Track<input className="input" value={f.track} onChange={(e) => setF({ ...f, track: e.target.value })} placeholder="e.g. Texas Motorplex" /></label>
        </div>
        <div className="form four">
          <UnitInput label="Reaction (s)" kind={null} value={f.rt} onChange={setN('rt')} digits={3} />
          <UnitInput label="60 ft (s)" kind={null} value={f.sixty} onChange={setN('sixty')} digits={3} />
          <UnitInput label="330 ft (s)" kind={null} value={f.threeThirty} onChange={setN('threeThirty')} digits={3} />
          <UnitInput label="⅛ ET (s)" kind={null} value={f.eighthEt} onChange={setN('eighthEt')} digits={3} />
          <UnitInput label="⅛ speed" kind="speed" value={f.eighthMph} onChange={setN('eighthMph')} digits={2} />
          <UnitInput label="¼ ET (s)" kind={null} value={f.quarterEt} onChange={setN('quarterEt')} digits={3} />
          <UnitInput label="¼ speed" kind="speed" value={f.quarterMph} onChange={setN('quarterMph')} digits={2} />
          <UnitInput label="DA from slip" kind="altitude" value={f.da} onChange={setN('da')} digits={0} hint="optional" />
        </div>
        <fieldset className="pressures wide">
          <legend>Weather (optional — fills DA if the slip has none)</legend>
          <UnitInput label="Temp" kind="temp" value={f.weather.tempF} onChange={setW('tempF')} digits={1} />
          <UnitInput label="Baro" kind="pressure" value={f.weather.pressureInHg} onChange={setW('pressureInHg')} digits={2} />
          <UnitInput label="RH %" kind={null} value={f.weather.humidity} onChange={setW('humidity')} digits={0} />
          <UnitInput label="Elev." kind="altitude" value={f.weather.elevationFt} onChange={setW('elevationFt')} digits={0} />
        </fieldset>
        {calc && f.da === null && <p className="muted">Calculated DA: {fmtQty('altitude', calc.daFt, u)}</p>}
        <p className="muted small">Mods snapshot: {mods.length ? mods.join(', ') : 'stock (no mods in Garage)'}</p>
        <label>Notes<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">Save timeslip</button>
      </form>

      <section className="card">
        <h2>Best &amp; consistency</h2>
        <div className="stats">
          <div className="stat"><div className="stat-v">{s3(stats.bestEt)}</div><div className="stat-l">Best ¼ ET</div></div>
          <div className="stat"><div className="stat-v">{stats.bestMph === null ? '—' : fmtQty('speed', stats.bestMph, u, 1)}</div><div className="stat-l">Best ¼ speed</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.bestSixty)}</div><div className="stat-l">Best 60 ft</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.bestRt)}</div><div className="stat-l">Best reaction</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.meanEt)}</div><div className="stat-l">Mean ¼ ET</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.sdEt)}</div><div className="stat-l">Std dev (consistency)</div></div>
          <div className="stat"><div className="stat-v">{s3(stats.spreadEt)}</div><div className="stat-l">ET spread</div></div>
          <div className="stat"><div className="stat-v">{stats.count}</div><div className="stat-l">Passes</div></div>
        </div>
        <EtTrend slips={sorted} />
      </section>

      <section className="card">
        <h2>Sourced stock passes</h2>
        <ul className="rows">
          {stock.map((p) => (
            <li key={p.record.id}><strong>{p.et.toFixed(2)} s{p.mph !== null && ` @ ${fmtQty('speed', p.mph, u)}`}</strong> — {p.record.label} <span className="tag">{p.record.car}</span>
              {stats.bestEt !== null && <span className="muted"> · your best {stats.bestEt - p.et <= 0 ? '−' : '+'}{Math.abs(stats.bestEt - p.et).toFixed(2)} s</span>} <Cite c={p.record.confidence} url={p.record.source} /></li>
          ))}
        </ul>
        <Note>Different tracks, prep, tires and weather. Compare loosely.</Note>
      </section>

      <DaCalculator />

      {sorted.length === 0 ? <p className="muted">No timeslips logged yet.</p> : [...sorted].reverse().map((s) => {
        const corr = s.quarterEt !== null && s.da !== null ? correctToSeaLevel(s.quarterEt, s.quarterMph, s.da) : null;
        if (s.gps) return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{GPS_LABEL[s.gps.kind]} <span className="badge badge-unverified">GPS estimate</span> <span className="muted small">{s.date}</span></h2>
              <button className="link-btn danger" onClick={() => { if (confirm('Delete this GPS run?')) setSlips(slips.filter((x) => x.id !== s.id)); }} aria-label={`Delete GPS run ${s.date}`}>Delete</button></div>
            <p><strong>{s.gps.seconds.toFixed(2)} s</strong>{s.gps.trapMph !== null && <> @ {fmtQty('speed', s.gps.trapMph, u, 1)}</>} <span className="muted">· worst accuracy ±{s.gps.accuracyM} m · not included in strip stats</span></p>
            <p className="muted small">Mods: {s.mods.length ? s.mods.join(', ') : 'stock'}</p>
          </section>
        );
        return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{s.track || 'Drag strip'} <span className="muted small">{s.date}</span></h2>
              <button className="link-btn danger" onClick={() => { if (confirm('Delete this timeslip?')) setSlips(slips.filter((x) => x.id !== s.id)); }} aria-label={`Delete timeslip ${s.date}`}>Delete</button></div>
            <table className="tbl slip">
              <tbody>
                <tr><th>R/T</th><td>{s3(s.rt)}</td><th>60 ft</th><td>{s3(s.sixty)}</td></tr>
                <tr><th>330 ft</th><td>{s3(s.threeThirty)}</td><th>DA</th><td>{fmtQty('altitude', s.da, u)}</td></tr>
                <tr><th>⅛ ET</th><td>{s3(s.eighthEt)}</td><th>⅛ speed</th><td>{fmtQty('speed', s.eighthMph, u, 2)}</td></tr>
                <tr><th>¼ ET</th><td><strong>{s3(s.quarterEt)}</strong></td><th>¼ speed</th><td><strong>{fmtQty('speed', s.quarterMph, u, 2)}</strong></td></tr>
              </tbody>
            </table>
            {corr && (
              <p className="muted">DA-corrected <span className="badge badge-unverified">estimate</span>: about <strong>{s2(corr.et)} s</strong>{corr.mph !== null && <> @ {fmtQty('speed', corr.mph, u, 1)}</>} at 0 ft DA — assumes power scales with air density; not an official correction.</p>
            )}
            <p className="muted small">Mods: {s.mods.length ? s.mods.join(', ') : 'stock'}</p>
            {s.notes && <p className="wrap">{s.notes}</p>}
          </section>
        );
      })}
    </>
  );
}
