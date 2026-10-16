import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Note } from '../components/Facts';
import { useUnits } from '../components/SettingsContext';
import { DRAG_KEY, loadDrag, type Timeslip } from '../lib/drag';
import { loadGarage, today, uid } from '../lib/garage';
import { MAX_ACCURACY_M, MPH, RUN_LABEL, accuracyState, analyzeRun, type Fix, type GpsResult, type RunKind } from '../lib/gps';
import { save } from '../lib/storage';
import { fmtQty } from '../lib/units';

type Phase = 'idle' | 'arming' | 'armed' | 'done' | 'denied' | 'unavailable';
const KEEP_MS = 120_000;

export function toFix(p: GeolocationPosition): Fix {
  return { t: p.timestamp, lat: p.coords.latitude, lon: p.coords.longitude, accuracy: p.coords.accuracy, speed: p.coords.speed ?? null };
}

export default function GpsMeter() {
  const u = useUnits();
  const supported = typeof navigator !== 'undefined' && !!navigator.geolocation;
  const [kind, setKind] = useState<RunKind>('0-60');
  const [phase, setPhase] = useState<Phase>(supported ? 'idle' : 'unavailable');
  const [last, setLast] = useState<Fix | null>(null);
  const [result, setResult] = useState<GpsResult | null>(null);
  const [errText, setErrText] = useState('');
  const [saved, setSaved] = useState('');
  const watchId = useRef<number | null>(null);
  const fixes = useRef<Fix[]>([]);

  const stop = () => { if (watchId.current !== null) navigator.geolocation.clearWatch(watchId.current); watchId.current = null; };
  useEffect(() => stop, []);

  // Only ever started by the Arm button — never automatically.
  const arm = () => {
    if (!supported) return;
    stop(); fixes.current = []; setResult(null); setSaved(''); setErrText(''); setLast(null); setPhase('arming');
    watchId.current = navigator.geolocation.watchPosition(
      (p) => {
        const f = toFix(p);
        fixes.current = [...fixes.current.filter((x) => f.t - x.t <= KEEP_MS), f];
        setLast(f); setPhase((ph) => (ph === 'arming' ? 'armed' : ph));
        const r = analyzeRun(kind, fixes.current);
        if (r.ok || r.final) { stop(); setResult(r); setPhase('done'); }
      },
      (e) => {
        stop();
        if (e.code === 1) { setPhase('denied'); setErrText('Location permission was denied. Enable it for this site in your browser settings to use the GPS meter; everything else in the app works without it.'); }
        else { setPhase('idle'); setErrText(e.code === 3 ? 'Timed out waiting for a GPS fix. Try again with a clear view of the sky.' : 'GPS position unavailable.'); }
      },
      { enableHighAccuracy: true, maximumAge: 0, timeout: 20000 },
    );
  };
  const cancel = () => { stop(); setPhase('idle'); };

  const saveRun = () => {
    if (!result?.ok) return;
    const slip: Timeslip = {
      id: uid(), date: today(), track: '', rt: null, sixty: null, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: null, quarterMph: null, da: null,
      weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false },
      mods: loadGarage().mods.map((m) => m.title),
      notes: `GPS estimate — ${RUN_LABEL[result.kind]}, worst accuracy ±${result.worstAccuracyM.toFixed(1)} m, ${result.fixes} fixes. Approximate; not a timeslip.`,
      gps: { kind: result.kind, seconds: Math.round(result.seconds * 100) / 100, trapMph: result.trapMph === null ? null : Math.round(result.trapMph * 10) / 10, accuracyM: Math.round(result.worstAccuracyM * 10) / 10 },
    };
    setSaved(save(DRAG_KEY, [...loadDrag(), slip]) ? 'Saved to the Drag log as a GPS estimate.' : 'This device refused to save (storage full or blocked).');
  };

  const acc = accuracyState(last?.accuracy ?? null);
  const speedMph = last ? (last.speed !== null ? last.speed / MPH : null) : null;
  const target = kind === '60-130' ? 'Get below 60 mph, then accelerate through 130 mph.' : kind === '0-60' ? 'Come to a complete stop, then launch through 60 mph.' : 'Come to a complete stop, then launch and run a full ¼ mile.';

  return (
    <>
      <h1>GPS Performance Meter</h1>
      <p className="lede"><span className="badge badge-unverified">approximate</span> Times 0–60 mph, 60–130 mph and ¼-mile runs from your phone's GPS. Phone GPS updates about once a second with metres of error, so results are <strong>estimates</strong> and are saved to the <Link to="/drag">Drag log</Link> labelled "GPS estimate", never as timeslips.</p>
      <div className="card warn"><strong>Only on a closed course or drag strip.</strong> Never on public roads. Mount the phone and do not touch it while driving. Location is used only on this device and only while armed.</div>
      <section className="card">
        <h2>Run</h2>
        <div role="radiogroup" aria-label="Run type" className="seg">
          {(Object.keys(RUN_LABEL) as RunKind[]).map((k) => (
            <button key={k} role="radio" aria-checked={kind === k} className={kind === k ? 'on' : ''} disabled={phase === 'arming' || phase === 'armed'} onClick={() => setKind(k)}>{RUN_LABEL[k]}</button>
          ))}
        </div>
        <p className="muted">{target}</p>
        <div className="timer-btns">
          {phase === 'arming' || phase === 'armed'
            ? <button className="big-btn stop" onClick={cancel}>Cancel</button>
            : <button className="big-btn go" onClick={arm} disabled={phase === 'unavailable'}>{phase === 'done' ? 'Arm again' : 'Arm GPS'}</button>}
        </div>
        <div className="stats" aria-live="polite">
          <div className="stat"><div className="stat-v">{phase === 'arming' ? 'Waiting…' : phase === 'armed' ? 'Armed' : phase === 'done' ? 'Done' : phase === 'denied' ? 'Denied' : phase === 'unavailable' ? 'No GPS' : 'Off'}</div><div className="stat-l">Status</div></div>
          <div className="stat"><div className={`stat-v acc-${acc}`}>{last ? `±${fmtQty('shortLength', last.accuracy / 0.3048, u, 0)}` : '—'}</div><div className="stat-l">Accuracy {acc === 'poor' ? '(too poor)' : acc === 'ok' ? '(good)' : ''}</div></div>
          <div className="stat"><div className="stat-v">{speedMph === null ? '—' : fmtQty('speed', speedMph, u, 0)}</div><div className="stat-l">Speed</div></div>
        </div>
        {phase === 'armed' && acc === 'poor' && <p className="warn-t" role="status">Accuracy is worse than ±{MAX_ACCURACY_M} m. A run timed now will be refused.</p>}
        {errText && <p className="err" role="alert">{errText}</p>}
        {phase === 'unavailable' && <p className="err">This browser has no Geolocation support.</p>}
      </section>
      {result && (
        <section className="card hl" aria-live="polite">
          <h2>Result</h2>
          {result.ok ? (
            <>
              <p className="stat-v">{result.seconds.toFixed(2)} s<small>{RUN_LABEL[result.kind]}{result.trapMph !== null && ` @ ${fmtQty('speed', result.trapMph, u, 1)}`}</small></p>
              <p className="muted">GPS estimate · worst accuracy ±{result.worstAccuracyM.toFixed(1)} m · {result.fixes} fixes. No rollout is subtracted (magazine 0–60 figures usually subtract a 1-ft rollout).</p>
              <button className="btn" onClick={saveRun} disabled={!!saved}>Save to Drag log</button>
              {saved && <p className="ok-t" role="status">{saved} <Link to="/drag">Open Drag log →</Link></p>}
            </>
          ) : <p className="err" role="alert">No result: {result.reason}</p>}
        </section>
      )}
      <Note>Method: launch is detected when speed rises through {1.5} mph and is back-extrapolated to zero; target speeds and the ¼-mile distance are linearly interpolated between fixes. Speed uses the receiver's Doppler speed when the phone reports it, otherwise distance between fixes. Any fix worse than ±{MAX_ACCURACY_M} m, or a gap over 2.5 s, inside the run makes the meter refuse to report.</Note>
    </>
  );
}
