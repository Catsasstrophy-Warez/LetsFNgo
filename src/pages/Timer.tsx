import { appendForActiveCar } from '../lib/carlog';
import { useCallback, useEffect, useState } from 'react';
import { createWakeLock, type Sentinel, type WakeState } from '../lib/wakelock';
import { Link } from 'react-router';
import { Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { KEYS, loadTrack, today, uid } from '../lib/garage';
import { formatLapTime } from '../lib/laptime';
import { bestLap, clock, currentLap, elapsed, lap, lapsToText, newWatch, pause, running, start, type Stopwatch } from '../lib/timer';

const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

/** Keep the screen on while the watch runs, where the Screen Wake Lock API exists. Falls back silently. */
function useWakeLock(active: boolean): WakeState {
  const supported = typeof navigator !== 'undefined' && 'wakeLock' in navigator;
  const [state, setState] = useState<WakeState>(supported ? 'off' : 'unsupported');
  useEffect(() => {
    if (!supported) return;
    const req = () => (navigator as unknown as { wakeLock: { request: (t: 'screen') => Promise<Sentinel> } }).wakeLock.request('screen');
    const lock = createWakeLock(req, setState, () => document.visibilityState === 'visible');
    lock.set(active);
    const onVis = () => { lock.acquire(); };
    document.addEventListener('visibilitychange', onVis);
    return () => { document.removeEventListener('visibilitychange', onVis); lock.dispose(); setState('off'); };
  }, [active, supported]);
  return state;
}


export default function Timer() {
  const tt = useT();
  const [w, setW] = useState<Stopwatch>(newWatch);
  const [t, setT] = useState(now);
  const [track, setTrack] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const isRunning = running(w);
  const wake = useWakeLock(isRunning);

  useEffect(() => {
    if (!isRunning) return;
    const id = setInterval(() => setT(now()), 50);
    return () => clearInterval(id);
  }, [isRunning]);

  const toggle = () => { const n = now(); setT(n); setW((x) => (running(x) ? pause(x, n) : start(x, n))); };
  const doLap = useCallback(() => { const n = now(); setT(n); setW((x) => lap(x, n)); }, []);
  const doReset = () => { if (!w.laps.length || confirm(tt('timer.confirmReset'))) { setW(newWatch()); setMsg(null); } };
  const doSave = () => {
    if (!w.laps.length) return setMsg({ ok: false, text: tt('timer.needLap') });
    if (!track.trim()) return setMsg({ ok: false, text: tt('track.errName') });
    const ok = appendForActiveCar(KEYS.track, loadTrack(), { id: uid(), date: today(), track: track.trim(), conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: lapsToText(w.laps), notes: `Timed with the session timer (${w.laps.length} laps, session ${clock(elapsed(w, t))}). Hand-timed — expect a few tenths of error.` });
    setMsg(ok ? { ok: true, text: tt('timer.saved', { n: w.laps.length }) } : { ok: false, text: tt('common.saveFailed') });
  };

  const best = bestLap(w.laps);
  return (
    <>
      <h1>{tt('nav.timer')}</h1>
      <p className="lede">{tt('timer.lede')}</p>
      <section className="card timer" aria-labelledby="timer-h">
        <h2 id="timer-h" className="sr-only">{tt('timer.sw')}</h2>
        <div className="timer-clock" aria-label={tt('timer.session', { t: clock(elapsed(w, t)) })}>{clock(elapsed(w, t))}</div>
        <div className="timer-lap muted">{tt('timer.lapN', { n: w.laps.length + 1 })} <span className="mono">{clock(currentLap(w, t))}</span></div>
        <div className="timer-btns">
          <button className={`big-btn ${isRunning ? 'stop' : 'go'}`} onClick={toggle}>{isRunning ? tt('timer.pause') : elapsed(w, t) > 0 ? tt('timer.resume') : tt('timer.start')}</button>
          <button className="big-btn" onClick={doLap} disabled={!isRunning}>{tt('timer.lap')}</button>
        </div>
        <div className="btn-row">
          <button className="btn ghost" onClick={doReset} disabled={isRunning || elapsed(w, t) === 0}>{tt('timer.reset')}</button>
        </div>
        <p className="muted small" role="status">{tt(`timer.wake.${wake}`)}</p>
      </section>
      <section className="card" aria-live="polite">
        <h2>{tt('timer.laps')}</h2>
        {w.laps.length === 0 ? <p className="muted">{tt('timer.noLaps')}</p> : (
          <ol className="rows lap-list">
            {w.laps.map((ms, i) => (
              <li key={i} className={ms === best ? 'best' : ''}><span>{tt('timer.lapI', { n: i + 1 })}</span> <strong className="mono">{formatLapTime(ms / 1000, 3)}</strong>{ms === best && <span className="tag">{tt('timer.best')}</span>}</li>
            ))}
          </ol>
        )}
        <div className="form">
          <label>{tt('track.track')}<input className="input" list="timer-tracks" value={track} onChange={(e) => setTrack(e.target.value)} placeholder={tt('track.trackPh')} /></label>
          <datalist id="timer-tracks"><option value="Laguna Seca" /><option value="VIR Grand Course" /></datalist>
        </div>
        <button className="btn" onClick={doSave}>{tt('timer.save')}</button>
        {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text} {msg.ok && <Link to="/track">{tt('timer.open')}</Link>}</p>}
        <Note>{tt('timer.note')}</Note>
      </section>
    </>
  );
}
