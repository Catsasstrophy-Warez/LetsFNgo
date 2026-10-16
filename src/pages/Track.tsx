import { useEffect, useState } from 'react';
import { Cite, Note } from '../components/Facts';
import { save } from '../lib/storage';
import { KEYS, loadTrack, today, uid, type TrackSession } from '../lib/garage';
import { formatLapTime, lapStats, parseLaps } from '../lib/laptime';
import { REFERENCE_TRACKS, referenceLaps } from '../lib/refLaps';

const blank = (): Omit<TrackSession, 'id'> => ({ date: today(), track: '', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: '', notes: '' });

function Delta({ mine, refSec }: { mine: number | null; refSec: number | null }) {
  if (mine === null || refSec === null) return null;
  const d = mine - refSec;
  return <span className="muted"> · your best {d <= 0 ? '−' : '+'}{Math.abs(d).toFixed(3)} s</span>;
}

export default function Track() {
  const [sessions, setSessions] = useState<TrackSession[]>(loadTrack);
  const [f, setF] = useState(blank);
  const [err, setErr] = useState('');
  useEffect(() => save(KEYS.track, sessions), [sessions]);
  const preview = parseLaps(f.laps);
  const setP = (k: keyof TrackSession['pressures'], v: string) => setF({ ...f, pressures: { ...f.pressures, [k]: v } });

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!f.track.trim()) return setErr('Enter a track name.');
    if (preview.bad.length) return setErr(`Could not read line ${preview.bad.join(', ')}. Use m:ss.sss, optionally "| s1 s2 s3".`);
    setErr('');
    setSessions([...sessions, { id: uid(), ...f }]);
    setF({ ...blank(), track: f.track, pressures: f.pressures });
  };

  return (
    <>
      <h1>Track Day Log</h1>
      <p className="lede">Log sessions on this device. Paste one lap per line as <code>1:35.214</code>; add sectors after a bar (<code>1:35.214 | 30.1 32.0 33.1</code>) to get a theoretical best. Reference laps are shown for {REFERENCE_TRACKS.join(' and ')}.</p>
      <form className="card form" onSubmit={submit} noValidate>
        <h2>New session</h2>
        <div className="form two">
          <label>Date<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>Track<input className="input" list="tracks" value={f.track} onChange={(e) => setF({ ...f, track: e.target.value })} placeholder="e.g. Laguna Seca" /></label>
          <label>Conditions<input className="input" value={f.conditions} onChange={(e) => setF({ ...f, conditions: e.target.value })} placeholder="Dry, sunny" /></label>
          <label>Air temp<input className="input" value={f.airTemp} onChange={(e) => setF({ ...f, airTemp: e.target.value })} placeholder="72°F" /></label>
        </div>
        <datalist id="tracks"><option value="Laguna Seca" /><option value="VIR Grand Course" /></datalist>
        <fieldset className="pressures">
          <legend>Tire pressures (psi)</legend>
          {(['fl', 'fr', 'rl', 'rr'] as const).map((k) => (
            <label key={k}>{k.toUpperCase()}<input className="input" inputMode="decimal" value={f.pressures[k]} onChange={(e) => setP(k, e.target.value)} /></label>
          ))}
        </fieldset>
        <label>Lap times<textarea className="input mono" rows={5} value={f.laps} onChange={(e) => setF({ ...f, laps: e.target.value })} placeholder={'1:36.402\n1:35.214 | 30.1 32.0 33.1'} /></label>
        {f.laps.trim() && <p className="muted">{preview.laps.length} lap{preview.laps.length === 1 ? '' : 's'} read{preview.bad.length ? ` · unreadable line ${preview.bad.join(', ')}` : ''}</p>}
        <label>Notes<textarea className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        {err && <p className="err" role="alert">{err}</p>}
        <button className="btn" type="submit">Save session</button>
      </form>
      {sessions.length === 0 ? <p className="muted">No sessions logged yet.</p> : [...sessions].sort((a, b) => b.date.localeCompare(a.date)).map((s) => {
        const st = lapStats(parseLaps(s.laps).laps);
        const refs = referenceLaps(s.track);
        const p = s.pressures;
        return (
          <section className="card" key={s.id}>
            <div className="row-main"><h2>{s.track}</h2><button className="link-btn danger" onClick={() => { if (confirm('Delete this session?')) setSessions(sessions.filter((x) => x.id !== s.id)); }} aria-label={`Delete ${s.track} session ${s.date}`}>Delete</button></div>
            <p className="muted">{s.date}{s.conditions && ` · ${s.conditions}`}{s.airTemp && ` · ${s.airTemp}`}{(p.fl || p.fr || p.rl || p.rr) && ` · psi FL ${p.fl || '—'} FR ${p.fr || '—'} RL ${p.rl || '—'} RR ${p.rr || '—'}`}</p>
            <div className="stats">
              <div className="stat"><div className="stat-v">{formatLapTime(st.best)}</div><div className="stat-l">Best</div></div>
              <div className="stat"><div className="stat-v">{formatLapTime(st.avg)}</div><div className="stat-l">Average</div></div>
              <div className="stat"><div className="stat-v">{formatLapTime(st.theoretical)}</div><div className="stat-l">Theoretical best</div></div>
              <div className="stat"><div className="stat-v">{st.count}</div><div className="stat-l">Laps</div></div>
            </div>
            {refs.length > 0 && (
              <>
                <div className="sub">Sourced reference laps</div>
                <ul className="rows">
                  {refs.map((r) => (
                    <li key={r.record.id}><strong>{r.record.result}</strong> — {r.record.label} <span className="tag">{r.record.car}</span><Delta mine={st.best} refSec={r.seconds} /> <Cite c={r.record.confidence} url={r.record.source} /></li>
                  ))}
                </ul>
                <Note>Track configurations, tires and drivers differ; treat comparisons loosely.</Note>
              </>
            )}
            {s.notes && <p>{s.notes}</p>}
          </section>
        );
      })}
    </>
  );
}
