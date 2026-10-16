import { useState } from 'react';
import { useCarLog } from '../components/CarContext';
import { Cite, Note } from '../components/Facts';
import { KEYS, loadTrack, today, uid, type TrackSession } from '../lib/garage';
import { formatLapTime, lapStats, parseLaps } from '../lib/laptime';
import { REFERENCE_TRACKS, referenceLaps } from '../lib/refLaps';
import { LapTrend } from '../components/Trends';
import { useT } from '../components/SettingsContext';

const blank = (): Omit<TrackSession, 'id'> => ({ date: today(), track: '', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: '', notes: '' });

function Delta({ mine, refSec }: { mine: number | null; refSec: number | null }) {
  const t = useT();
  if (mine === null || refSec === null) return null;
  const d = mine - refSec;
  return <span className="muted"> · {t('track.yourBest')} {d <= 0 ? '−' : '+'}{Math.abs(d).toFixed(3)} s</span>;
}

export default function Track() {
  const t = useT();
  const [sessions, setSessions] = useCarLog<TrackSession>(KEYS.track, loadTrack);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  const preview = parseLaps(f.laps);
  const setP = (k: keyof TrackSession['pressures'], v: string) => setF({ ...f, pressures: { ...f.pressures, [k]: v } });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!f.track.trim()) return setErr(t('track.errName'));
    if (preview.bad.length) return setErr(t('track.errLaps', { l: preview.bad.join(', ') }));
    setErr('');
    setSessions([...sessions, { id: uid(), ...f }]);
    setF({ ...blank(), track: f.track, pressures: f.pressures });
  };

  return (
    <>
      <h1>{t('nav.track')}</h1>
      <p className="lede">{t('track.lede', { tracks: REFERENCE_TRACKS.join(' · ') })}</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>{t('track.new')}</h2>
        <div className="form two">
          <label>{t('log.date')}<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>{t('track.track')}<input className="input" list="tracks" value={f.track} onChange={(e) => setF({ ...f, track: e.target.value })} placeholder={t('track.trackPh')} /></label>
          <label>{t('track.conditions')}<input className="input" value={f.conditions} onChange={(e) => setF({ ...f, conditions: e.target.value })} placeholder={t('track.conditionsPh')} /></label>
          <label>{t('track.airTemp')}<input className="input" value={f.airTemp} onChange={(e) => setF({ ...f, airTemp: e.target.value })} placeholder="72°F" /></label>
        </div>
        <datalist id="tracks"><option value="Laguna Seca" /><option value="VIR Grand Course" /></datalist>
        <fieldset className="pressures">
          <legend>{t('track.pressures')}</legend>
          {(['fl', 'fr', 'rl', 'rr'] as const).map((k) => (
            <label key={k}>{k.toUpperCase()}<input className="input" inputMode="decimal" value={f.pressures[k]} onChange={(e) => setP(k, e.target.value)} /></label>
          ))}
        </fieldset>
        <label>{t('track.laps')}<textarea className="input mono" rows={5} value={f.laps} onChange={(e) => setF({ ...f, laps: e.target.value })} placeholder={'1:36.402\n1:35.214 | 30.1 32.0 33.1'} /></label>
        {f.laps.trim() && <p className="muted">{t('track.read', { n: preview.laps.length })}{preview.bad.length ? ` · ${t('track.unreadable', { l: preview.bad.join(', ') })}` : ''}</p>}
        <label>{t('log.notes')}<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">{t('track.save')}</button>
      </form>
      {sessions.length > 0 && <section className="card"><h2>{t('track.trend')}</h2><LapTrend sessions={sessions} /></section>}
      {sessions.length === 0 ? <p className="muted">{t('track.empty')}</p> : [...sessions].sort((a, b) => b.date.localeCompare(a.date)).map((s) => {
        const st = lapStats(parseLaps(s.laps).laps);
        const refs = referenceLaps(s.track);
        const p = s.pressures;
        return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{s.track}</h2><button className="link-btn danger" onClick={() => { if (confirm(t('track.confirmDelete'))) setSessions(sessions.filter((x) => x.id !== s.id)); }} aria-label={t('track.deleteLabel', { t: s.track, d: s.date })}>{t('common.delete')}</button></div>
            <p className="muted">{s.date}{s.conditions && ` · ${s.conditions}`}{s.airTemp && ` · ${s.airTemp}`}{(p.fl || p.fr || p.rl || p.rr) && ` · psi FL ${p.fl || '—'} FR ${p.fr || '—'} RL ${p.rl || '—'} RR ${p.rr || '—'}`}</p>
            <div className="stats">
              <div className="stat"><div className="stat-v">{formatLapTime(st.best)}</div><div className="stat-l">{t('track.best')}</div></div>
              <div className="stat"><div className="stat-v">{formatLapTime(st.avg)}</div><div className="stat-l">{t('track.avg')}</div></div>
              <div className="stat"><div className="stat-v">{formatLapTime(st.theoretical)}</div><div className="stat-l">{t('track.theoretical')}</div></div>
              <div className="stat"><div className="stat-v">{st.count}</div><div className="stat-l">{t('track.lapsCount')}</div></div>
            </div>
            {refs.length > 0 && (
              <>
                <div className="sub">{t('track.refs')}</div>
                <ul className="rows">
                  {refs.map((r) => (
                    <li key={r.record.id}><strong>{r.record.result}</strong> — {r.record.label} <span className="tag">{r.record.car}</span><Delta mine={st.best} refSec={r.seconds} /> <Cite c={r.record.confidence} url={r.record.source} /></li>
                  ))}
                </ul>
                <Note>{t('track.refsNote')}</Note>
              </>
            )}
            {s.notes && <p>{s.notes}</p>}
          </section>
        );
      })}
    </>
  );
}
