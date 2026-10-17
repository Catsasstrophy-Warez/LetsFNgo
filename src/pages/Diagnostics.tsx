import { useEffect, useState } from 'react';
import { Link } from 'react-router';
import { useT } from '../components/SettingsContext';
import { Note } from '../components/Facts';
import { downloadText } from '../lib/download';
import { today } from '../lib/garage';
import { clearDiag, diagExport, flushDiag, loadDiag, resetDiagCache, setDiagEnabled, summarizeDiag, type DiagEntry, type DiagStore } from '../lib/diag';

const line = (e: DiagEntry): string => {
  const ts = `${(e.t / 1000).toFixed(1)} s`;
  switch (e.k) {
    case 'gps': return `${ts} · GPS ±${e.acc} m${e.dtMs !== null ? ` · Δ${e.dtMs} ms` : ''}${e.mps !== null ? ` · ${e.mps} m/s` : ''}`;
    case 'lap': return `${ts} · lap ${e.n} ${e.s.toFixed(3)} s${e.valid ? '' : ' (refused)'} · ±${e.accM} m · dir ${e.dir}`;
    case 'obd': return `${ts} · OBD ${e.cmd} ${e.ok ? `${e.bytes} B` : e.err ?? 'error'} · ${e.ms} ms`;
    case 'evt': return `${ts} · ${e.src} ${e.ev}`;
  }
};

/** Settings → Diagnostics: opt-in, local-only field-test log (GPS fix quality, lap crossings, OBD timing). */
export default function Diagnostics() {
  const t = useT();
  const [s, setS] = useState<DiagStore>(() => { flushDiag(); resetDiagCache(); return loadDiag(); });
  const [msg, setMsg] = useState<string | null>(null);
  // Refresh while open so entries recorded in another tab / by a running timer show up.
  useEffect(() => {
    const id = setInterval(() => { flushDiag(); resetDiagCache(); setS(loadDiag()); }, 3000);
    return () => clearInterval(id);
  }, []);
  const sum = summarizeDiag(s.entries);
  const f = (v: number | null, unit: string) => (v === null ? '—' : `${v} ${unit}`);

  return (
    <>
      <h1>{t('diag.title')}</h1>
      <p className="lede">{t('diag.lede')} <Link to="/settings">{t('nav.settings')} →</Link></p>
      <div className="card warn" role="note">{t('diag.privacy')}</div>
      <section className="card">
        <h2>{t('diag.recording')}</h2>
        <label className="check">
          <input type="checkbox" checked={s.enabled} onChange={(e) => setS(setDiagEnabled(e.target.checked))} />
          <span>{t('diag.record')}</span>
        </label>
        <p className="muted small" role="status">{s.enabled ? t('diag.on') : t('diag.off')}</p>
        <div className="stats">
          <div className="stat"><div className="stat-v">{sum.gps}</div><div className="stat-l">{t('diag.gps')}</div></div>
          <div className="stat"><div className="stat-v">{f(sum.accP50, 'm')}</div><div className="stat-l">{t('diag.accP50')}</div></div>
          <div className="stat"><div className="stat-v">{f(sum.accP95, 'm')}</div><div className="stat-l">{t('diag.accP95')}</div></div>
          <div className="stat"><div className="stat-v">{f(sum.dtP50, 'ms')}</div><div className="stat-l">{t('diag.dtP50')}</div></div>
          <div className="stat"><div className="stat-v">{f(sum.dtMax, 'ms')}</div><div className="stat-l">{t('diag.dtMax')}</div></div>
          <div className="stat"><div className="stat-v">{sum.laps}</div><div className="stat-l">{t('diag.laps')}</div></div>
          <div className="stat"><div className="stat-v">{sum.obd}</div><div className="stat-l">{t('diag.obd')}</div></div>
          <div className="stat"><div className="stat-v">{sum.obdFail}</div><div className="stat-l">{t('diag.obdFail')}</div></div>
          <div className="stat"><div className="stat-v">{f(sum.obdP50, 'ms')}</div><div className="stat-l">{t('diag.obdP50')}</div></div>
        </div>
        <div className="btn-row">
          <button className="btn" disabled={!s.entries.length} onClick={() => { flushDiag(); downloadText(diagExport(s), `gt500-diagnostics-${today()}.json`, 'application/json'); setMsg(t('diag.exported', { n: s.entries.length })); }}>{t('diag.export')}</button>
          <button className="btn ghost" disabled={!s.entries.length} onClick={() => { if (confirm(t('diag.confirmClear'))) { setS(clearDiag()); setMsg(null); } }}>{t('diag.clear')}</button>
        </div>
        {msg && <p className="ok-t" role="status">{msg}</p>}
      </section>
      <section className="card">
        <h2>{t('diag.recent')}</h2>
        {s.entries.length === 0 ? <p className="muted">{t('diag.empty')}</p> : (
          <ol className="rows small mono" reversed>
            {s.entries.slice(-50).reverse().map((e, i) => <li key={`${e.t}-${i}`}>{line(e)}</li>)}
          </ol>
        )}
      </section>
      <Note>{t('diag.note')}</Note>
    </>
  );
}
