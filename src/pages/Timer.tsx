import { useCallback, useEffect, useState } from 'react';
import { createWakeLock, type Sentinel, type WakeState } from '../lib/wakelock';
import { Link } from 'react-router';
import { Note } from '../components/Facts';
import { KEYS, loadTrack, today, uid } from '../lib/garage';
import { save } from '../lib/storage';
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

const WAKE_TEXT: Record<WakeState, string> = {
  unsupported: 'Screen wake lock is not available in this browser — keep the screen on manually.',
  off: 'Screen will be kept on while the timer runs.',
  on: 'Screen is being kept on.',
  failed: 'Could not keep the screen on (battery saver or permission). Keep it on manually.',
};

export default function Timer() {
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
  const doReset = () => { if (!w.laps.length || confirm('Clear the timer and its laps?')) { setW(newWatch()); setMsg(null); } };
  const doSave = () => {
    if (!w.laps.length) return setMsg({ ok: false, text: 'Record at least one lap first.' });
    if (!track.trim()) return setMsg({ ok: false, text: 'Enter a track name.' });
    const ok = save(KEYS.track, [...loadTrack(), { id: uid(), date: today(), track: track.trim(), conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: lapsToText(w.laps), notes: `Timed with the session timer (${w.laps.length} laps, session ${clock(elapsed(w, t))}). Hand-timed — expect a few tenths of error.` }]);
    setMsg(ok ? { ok: true, text: `Saved ${w.laps.length} lap${w.laps.length === 1 ? '' : 's'} to the Track log.` } : { ok: false, text: 'This device refused to save (storage full or blocked).' });
  };

  const best = bestLap(w.laps);
  return (
    <>
      <h1>Session Timer</h1>
      <p className="lede">A stopwatch with lap splits for track and drag days. Tap <strong>Lap</strong> as you cross your marker; laps save straight into the <Link to="/track">Track log</Link>. Do not operate your phone while driving — have a passenger or crew member time.</p>
      <section className="card timer" aria-labelledby="timer-h">
        <h2 id="timer-h" className="sr-only">Stopwatch</h2>
        <div className="timer-clock" aria-label={`Session time ${clock(elapsed(w, t))}`}>{clock(elapsed(w, t))}</div>
        <div className="timer-lap muted">Lap {w.laps.length + 1}: <span className="mono">{clock(currentLap(w, t))}</span></div>
        <div className="timer-btns">
          <button className={`big-btn ${isRunning ? 'stop' : 'go'}`} onClick={toggle}>{isRunning ? 'Pause' : elapsed(w, t) > 0 ? 'Resume' : 'Start'}</button>
          <button className="big-btn" onClick={doLap} disabled={!isRunning}>Lap</button>
        </div>
        <div className="btn-row">
          <button className="btn ghost" onClick={doReset} disabled={isRunning || elapsed(w, t) === 0}>Reset</button>
        </div>
        <p className="muted small" role="status">{WAKE_TEXT[wake]}</p>
      </section>
      <section className="card" aria-live="polite">
        <h2>Laps</h2>
        {w.laps.length === 0 ? <p className="muted">No laps yet.</p> : (
          <ol className="rows lap-list">
            {w.laps.map((ms, i) => (
              <li key={i} className={ms === best ? 'best' : ''}><span>Lap {i + 1}</span> <strong className="mono">{formatLapTime(ms / 1000, 3)}</strong>{ms === best && <span className="tag">best</span>}</li>
            ))}
          </ol>
        )}
        <div className="form">
          <label>Track<input className="input" list="timer-tracks" value={track} onChange={(e) => setTrack(e.target.value)} placeholder="e.g. Laguna Seca" /></label>
          <datalist id="timer-tracks"><option value="Laguna Seca" /><option value="VIR Grand Course" /></datalist>
        </div>
        <button className="btn" onClick={doSave}>Save to Track log</button>
        {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text} {msg.ok && <Link to="/track">Open Track log →</Link>}</p>}
        <Note>Laps shorter than 1 s are ignored so a double tap cannot add a phantom lap. Hand timing is less accurate than a transponder.</Note>
      </section>
    </>
  );
}
