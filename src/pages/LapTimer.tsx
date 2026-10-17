import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { useT, useUnits } from '../components/SettingsContext';
import { tracks } from '../data/tracks';
import { cleanFixes, MPH, type Fix } from '../lib/gps';
import { KEYS, activeCarId, loadTrack, today, uid, type TrackSession } from '../lib/garage';
import { save } from '../lib/storage';
import {
  LAP_MAX_ACCURACY_M, LAP_MAX_GAP_MS, MAX_SECTORS, fmtLap, lineFromHeading, lineFromPoints, liveState, nearestFacility, pruneTraces, sessionFromFixes, type TimingLine,
} from '../lib/lapTimer';
import { parseCoords } from '../lib/weather';
import { fmtQty } from '../lib/units';

type Phase = 'idle' | 'running' | 'denied' | 'unavailable';
/** Longest session kept in memory (fixes older than this are dropped from the live buffer). */
const KEEP_MS = 3 * 60 * 60 * 1000;

const toFix = (p: GeolocationPosition): Fix => ({ t: p.timestamp, lat: p.coords.latitude, lon: p.coords.longitude, accuracy: p.coords.accuracy, speed: p.coords.speed ?? null });

export default function LapTimer() {
  const t = useT();
  const u = useUnits();
  const supported = typeof navigator !== 'undefined' && !!navigator.geolocation;
  const [phase, setPhase] = useState<Phase>(supported ? 'idle' : 'unavailable');
  const [fixes, setFixes] = useState<Fix[]>([]);
  const [line, setLine] = useState<TimingLine | null>(null);
  const [sectors, setSectors] = useState<TimingLine[]>([]);
  const [pts, setPts] = useState({ aLat: '', aLon: '', bLat: '', bLon: '' });
  const [name, setName] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const watchId = useRef<number | null>(null);

  const stopWatch = () => { if (watchId.current !== null) navigator.geolocation.clearWatch(watchId.current); watchId.current = null; };
  useEffect(() => stopWatch, []);

  // GPS only ever starts from the Start button — never automatically.
  const start = () => {
    if (!supported) return;
    stopWatch(); setFixes([]); setMsg(null); setPhase('running');
    watchId.current = navigator.geolocation.watchPosition(
      (p) => { const f = toFix(p); setFixes((cur) => cleanFixes([...cur.filter((x) => f.t - x.t <= KEEP_MS), f])); },
      (e) => { stopWatch(); setPhase(e.code === 1 ? 'denied' : 'idle'); setMsg({ ok: false, text: e.code === 1 ? t('gps.denied') : e.code === 3 ? t('gps.timeout') : t('gps.unavailable') }); },
      { enableHighAccuracy: true, maximumAge: 0, timeout: 20000 },
    );
  };

  const last = fixes[fixes.length - 1] ?? null;
  const prev = fixes[fixes.length - 2] ?? null;
  const live = useMemo(() => (line && fixes.length > 1 ? liveState(fixes, line, { sectors }) : null), [fixes, line, sectors]);
  const hint = last ? nearestFacility(last, tracks) : null;

  const dropHere = (asSector: boolean) => {
    if (!last || !prev) return setMsg({ ok: false, text: t('lt.needMove') });
    if (last.accuracy > LAP_MAX_ACCURACY_M) return setMsg({ ok: false, text: t('lt.poorDrop', { m: LAP_MAX_ACCURACY_M }) });
    const l = lineFromHeading(prev, last);
    if (!l) return setMsg({ ok: false, text: t('lt.needMove') });
    setMsg(null);
    if (asSector) setSectors((s) => (s.length < MAX_SECTORS ? [...s, l] : s));
    else setLine(l);
  };
  const setFromPoints = () => {
    const a = parseCoords(pts.aLat, pts.aLon), b = parseCoords(pts.bLat, pts.bLon);
    if (!a || !b) return setMsg({ ok: false, text: t('lt.badPoints') });
    setLine(lineFromPoints(a, b)); setMsg(null);
  };

  /** Stop and auto-save the session into the Track log (only when at least one lap was completed). */
  const stop = () => {
    stopWatch(); setPhase('idle');
    if (!line) return;
    const s = sessionFromFixes(fixes, line, sectors);
    if (!s || !s.laps.length) return setMsg({ ok: false, text: t('lt.noLaps') });
    const valid = s.laps.filter((l) => l.valid).length;
    const entry: TrackSession = {
      id: uid(), date: today(), track: name.trim() || t('lt.defaultName'), conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' },
      laps: s.text, notes: t('lt.notes', { n: s.laps.length, v: valid, m: LAP_MAX_ACCURACY_M }), carId: activeCarId(), gps: s.gps,
    };
    const ok = save(KEYS.track, pruneTraces([...loadTrack(), entry]));
    setMsg({ ok, text: ok ? t('lt.saved', { n: valid }) : t('common.saveFailed') });
  };

  const running = phase === 'running';
  const accOk = last ? last.accuracy <= LAP_MAX_ACCURACY_M : false;
  const speed = last ? (last.speed !== null ? last.speed / MPH : null) : null;
  const delta = live?.deltaS ?? null;

  return (
    <>
      <h1>{t('nav.laptimer')}</h1>
      <p className="lede"><span className="badge badge-unverified">{t('gps.approx')}</span> {t('lt.lede')} <Link to="/track">{t('nav.track')} →</Link></p>
      <div className="card warn"><strong>{t('gps.warnStrong')}</strong> {t('lt.warn')}</div>

      <section className="card">
        <h2>{t('lt.session')}</h2>
        <label>{t('track.track')}<input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder={t('track.trackPh')} /></label>
        {hint && (
          <p className="muted" role="status">
            {t('lt.near', { name: hint.track.name, d: fmtQty('distance', hint.distM / 1609.344, u, 1) })}{' '}
            <button className="link-btn" onClick={() => setName(hint.track.name)}>{t('lt.useName')}</button> <Cite c={hint.track.confidence} url={hint.track.source} />
            <br /><span className="small">{t('lt.facilityNote')}</span>
          </p>
        )}
        <div className="timer-btns">
          {running
            ? <button className="big-btn stop" onClick={stop}>{t('lt.stop')}</button>
            : <button className="big-btn go" onClick={start} disabled={phase === 'unavailable'}>{t('lt.start')}</button>}
        </div>
        <div className="stats" aria-live="polite">
          <div className="stat"><div className={`stat-v acc-${last ? (accOk ? 'ok' : 'poor') : 'none'}`}>{last ? `±${fmtQty('shortLength', last.accuracy / 0.3048, u, 0)}` : '—'}</div><div className="stat-l">{t('gps.accuracy')}</div></div>
          <div className="stat"><div className="stat-v">{speed === null ? '—' : fmtQty('speed', speed, u, 0)}</div><div className="stat-l">{t('gps.speed')}</div></div>
        </div>
        {running && last && !accOk && <p className="warn-t" role="status">{t('lt.poorWarn', { m: LAP_MAX_ACCURACY_M })}</p>}
        {phase === 'unavailable' && <p className="err">{t('gps.noGeo')}</p>}
        {msg && <p className={msg.ok ? 'ok-t' : 'err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}{msg.ok && <> <Link to="/track">{t('gps.open')}</Link></>}</p>}
      </section>

      <section className="card">
        <h2>{t('lt.line')}</h2>
        <p className="muted">{line ? t('lt.lineSet', { s: sectors.length }) : t('lt.noLine')}</p>
        <div className="btn-row">
          <button className="btn" onClick={() => dropHere(false)} disabled={!running}>{t('lt.dropHere')}</button>
          <button className="btn ghost" onClick={() => dropHere(true)} disabled={!running || !line || sectors.length >= MAX_SECTORS}>{t('lt.addSector')}</button>
          {(line || sectors.length > 0) && <button className="btn ghost" onClick={() => { setLine(null); setSectors([]); }}>{t('lt.clearLine')}</button>}
        </div>
        <details>
          <summary>{t('lt.twoPoints')}</summary>
          <div className="form two">
            <label>{t('lt.aLat')}<input className="input" inputMode="decimal" value={pts.aLat} onChange={(e) => setPts({ ...pts, aLat: e.target.value })} /></label>
            <label>{t('lt.aLon')}<input className="input" inputMode="decimal" value={pts.aLon} onChange={(e) => setPts({ ...pts, aLon: e.target.value })} /></label>
            <label>{t('lt.bLat')}<input className="input" inputMode="decimal" value={pts.bLat} onChange={(e) => setPts({ ...pts, bLat: e.target.value })} /></label>
            <label>{t('lt.bLon')}<input className="input" inputMode="decimal" value={pts.bLon} onChange={(e) => setPts({ ...pts, bLon: e.target.value })} /></label>
          </div>
          <button className="btn ghost" onClick={setFromPoints}>{t('lt.setPoints')}</button>
        </details>
      </section>

      {line && (
        <section className="card hl" aria-live="polite">
          <h2>{t('lt.live')}</h2>
          <div className="stats">
            <div className="stat"><div className="stat-v">{live?.lapNo ? live.lapNo : '—'}</div><div className="stat-l">{t('lt.lap')}</div></div>
            <div className="stat"><div className="stat-v mono">{live?.elapsedS != null ? fmtLap(live.elapsedS) : '—'}</div><div className="stat-l">{t('lt.current')}</div></div>
            <div className="stat"><div className="stat-v mono">{live?.lastLap ? (live.lastLap.valid ? fmtLap(live.lastLap.seconds) : t('lt.refused')) : '—'}</div><div className="stat-l">{t('lt.last')}</div></div>
            <div className="stat"><div className="stat-v mono">{live?.best ? fmtLap(live.best.seconds) : '—'}</div><div className="stat-l">{t('track.best')}</div></div>
            <div className="stat"><div className={`stat-v mono ${delta === null ? '' : delta <= 0 ? 'ok-t' : 'err'}`}>{delta === null ? '—' : `${delta <= 0 ? '−' : '+'}${Math.abs(delta).toFixed(2)} s`}</div><div className="stat-l">{t('lt.delta')}</div></div>
          </div>
          {live && live.laps.length > 0 && (
            <ol className="rows">
              {live.laps.map((l) => (
                <li key={l.n}>
                  <strong className="mono">{fmtLap(l.seconds)}</strong>{l.sectors && <span className="muted mono"> | {l.sectors.map((x) => x.toFixed(2)).join(' ')}</span>}
                  {' '}<span className="muted">±{l.worstAccuracyM.toFixed(1)} m</span>
                  {!l.valid && <span className="err"> — {l.reason === 'accuracy' ? t('lt.refAcc', { m: LAP_MAX_ACCURACY_M }) : t('lt.refGap', { s: LAP_MAX_GAP_MS / 1000 })}</span>}
                </li>
              ))}
            </ol>
          )}
        </section>
      )}
      <Note>{t('lt.method', { m: LAP_MAX_ACCURACY_M, s: LAP_MAX_GAP_MS / 1000 })}</Note>
    </>
  );
}
