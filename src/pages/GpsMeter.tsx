import { appendForActiveCar } from '../lib/carlog';
import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Note } from '../components/Facts';
import { useT, useUnits } from '../components/SettingsContext';
import { tr, type MsgKey } from '../lib/i18n';
import { DRAG_KEY, loadDrag, type Timeslip } from '../lib/drag';
import { loadGarage, today, uid } from '../lib/garage';
import { MAX_ACCURACY_M, MPH, RUN_LABEL, accuracyState, analyzeRun, type Fix, type GpsResult, type RunKind } from '../lib/gps';
import { fmtQty } from '../lib/units';

type Phase = 'idle' | 'arming' | 'armed' | 'done' | 'denied' | 'unavailable';
const KEEP_MS = 120_000;

export function toFix(p: GeolocationPosition): Fix {
  return { t: p.timestamp, lat: p.coords.latitude, lon: p.coords.longitude, accuracy: p.coords.accuracy, speed: p.coords.speed ?? null };
}

const REASONS: Record<string, MsgKey> = {
  'Not enough GPS fixes.': 'gps.r.fixes', 'No launch from a stop was detected.': 'gps.r.launch', '60 mph was not reached.': 'gps.r.60',
  'A full ¼ mile was not covered.': 'gps.r.quarter', 'Speed never rose through 60 mph.': 'gps.r.through60', '130 mph was not reached.': 'gps.r.130', 'GPS fixes were too far apart.': 'gps.r.gap',
};
/** Translate a refusal reason from lib/gps (English, also used in tests). */
export function reasonText(r: string): string {
  if (REASONS[r]) return tr(REASONS[r]);
  const m = /worst ±(\d+) m; need ±(\d+) m/.exec(r);
  return m ? tr('gps.r.acc', { w: m[1], n: m[2] }) : r;
}

export default function GpsMeter() {
  const u = useUnits();
  const t = useT();
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
        if (e.code === 1) { setPhase('denied'); setErrText(t('gps.denied')); }
        else { setPhase('idle'); setErrText(e.code === 3 ? t('gps.timeout') : t('gps.unavailable')); }
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
    setSaved(appendForActiveCar(DRAG_KEY, loadDrag(), slip) ? t('gps.saved') : t('common.saveFailed'));
  };

  const acc = accuracyState(last?.accuracy ?? null);
  const speedMph = last ? (last.speed !== null ? last.speed / MPH : null) : null;
  const target = t(`gps.target.${kind}`);

  return (
    <>
      <h1>{t('gps.title')}</h1>
      <p className="lede"><span className="badge badge-unverified">{t('gps.approx')}</span> {t('gps.lede')} <Link to="/drag">{t('nav.drag')} →</Link></p>
      <div className="card warn"><strong>{t('gps.warnStrong')}</strong> {t('gps.warn')}</div>
      <section className="card">
        <h2>{t('gps.run')}</h2>
        <div role="radiogroup" aria-label={t('gps.runType')} className="seg">
          {(Object.keys(RUN_LABEL) as RunKind[]).map((k) => (
            <button key={k} role="radio" aria-checked={kind === k} className={kind === k ? 'on' : ''} disabled={phase === 'arming' || phase === 'armed'} onClick={() => setKind(k)}>{t(`drag.gps.${k}`)}</button>
          ))}
        </div>
        <p className="muted">{target}</p>
        <div className="timer-btns">
          {phase === 'arming' || phase === 'armed'
            ? <button className="big-btn stop" onClick={cancel}>{t('gps.cancel')}</button>
            : <button className="big-btn go" onClick={arm} disabled={phase === 'unavailable'}>{phase === 'done' ? t('gps.armAgain') : t('gps.arm')}</button>}
        </div>
        <div className="stats" aria-live="polite">
          <div className="stat"><div className="stat-v">{t(`gps.st.${phase}`)}</div><div className="stat-l">{t('gps.status')}</div></div>
          <div className="stat"><div className={`stat-v acc-${acc}`}>{last ? `±${fmtQty('shortLength', last.accuracy / 0.3048, u, 0)}` : '—'}</div><div className="stat-l">{t('gps.accuracy')} {acc === 'poor' ? t('gps.poor') : acc === 'ok' ? t('gps.good') : ''}</div></div>
          <div className="stat"><div className="stat-v">{speedMph === null ? '—' : fmtQty('speed', speedMph, u, 0)}</div><div className="stat-l">{t('gps.speed')}</div></div>
        </div>
        {phase === 'armed' && acc === 'poor' && <p className="warn-t" role="status">{t('gps.poorWarn', { m: MAX_ACCURACY_M })}</p>}
        {errText && <p className="err" role="alert">{errText}</p>}
        {phase === 'unavailable' && <p className="err">{t('gps.noGeo')}</p>}
      </section>
      {result && (
        <section className="card hl" aria-live="polite">
          <h2>{t('gps.result')}</h2>
          {result.ok ? (
            <>
              <p className="stat-v">{result.seconds.toFixed(2)} s<small>{t(`drag.gps.${result.kind}`)}{result.trapMph !== null && ` @ ${fmtQty('speed', result.trapMph, u, 1)}`}</small></p>
              <p className="muted">{t('gps.resultNote', { m: result.worstAccuracyM.toFixed(1), n: result.fixes })}</p>
              <button className="btn" onClick={saveRun} disabled={!!saved}>{t('gps.save')}</button>
              {saved && <p className="ok-t" role="status">{saved} <Link to="/drag">{t('gps.open')}</Link></p>}
            </>
          ) : <p className="err" role="alert">{t('gps.noResult', { r: reasonText(result.reason) })}</p>}
        </section>
      )}
      <Note>{t('gps.method', { s: 1.5, m: MAX_ACCURACY_M })}</Note>
    </>
  );
}
