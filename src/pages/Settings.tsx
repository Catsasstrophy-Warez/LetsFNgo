import { useEffect, useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router';
import { saveOnboarding } from '../lib/onboarding';
import { useSettings, useT } from '../components/SettingsContext';
import { LANGS, type Lang } from '../lib/i18n';
import { Note } from '../components/Facts';
import { MAX_IMPORT_BYTES, SCHEMA_VERSION, currentBackup, parseBackup, resetAll, restoreBackup } from '../lib/backup';
import { today } from '../lib/garage';
import { checkReminders, loadNotify, notifySupport, requestPermission, saveNotify, type Support } from '../lib/notify';
import type { ThemePref, Units } from '../lib/units';

function Seg<T extends string>({ label, value, options, onChange }: { label: string; value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return (
    <div role="radiogroup" aria-label={label} className="seg">
      {options.map(([v, l]) => (
        <button key={v} role="radio" aria-checked={value === v} className={value === v ? 'on' : ''} onClick={() => onChange(v)}>{l}</button>
      ))}
    </div>
  );
}

export function DataManagement() {
  const { setSettings } = useSettings();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const exportAll = () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(currentBackup(), null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = `gt500-companion-backup-${today()}.json`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setMsg({ ok: true, text: 'Backup downloaded.' });
  };
  const importFile = async (file: File) => {
    if (file.size > MAX_IMPORT_BYTES) return setMsg({ ok: false, text: `Import failed: file is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB.` });
    const r = parseBackup(await file.text());
    if (!r.ok) return setMsg({ ok: false, text: `Import failed: ${r.errors.slice(0, 4).join('; ')}` });
    if (!confirm('Replace Garage, plans, track sessions, timeslips, fill-ups, dyno pulls and settings on this device with the backup?')) return;
    if (!restoreBackup(r.data)) return setMsg({ ok: false, text: 'Import failed: this device refused to save the data (storage full or blocked). Nothing may have been restored.' });
    setSettings(r.data.settings);
    const d = r.data;
    setMsg({ ok: true, text: `Imported ${d.plans.length} plan(s), ${d.track.length} session(s), ${d.drag.length} timeslip(s) and ${d.fuel.length} fill-up(s)${r.migratedFrom ? ` (upgraded from schema v${r.migratedFrom})` : ''}.` });
  };
  return (
    <section className="card" id="data">
      <h2>Data management</h2>
      <p className="muted">Everything is stored only on this device. Export writes one JSON file (schema v{SCHEMA_VERSION}) with Garage, reminders, build plans, track sessions, drag timeslips (including GPS estimates), fuel log, settings and intro state, dyno pulls, notification preference and Home layout. Older v1–v3 backups still import.</p>
      <div className="btn-row">
        <button className="btn" onClick={exportAll}>Export JSON</button>
        <label className="btn ghost file-btn">Import JSON<input type="file" accept="application/json,.json" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; if (f) importFile(f); e.target.value = ''; }} /></label>
        <button className="btn ghost danger-btn" onClick={() => { if (confirm('Erase ALL GT500 Companion data on this device? This cannot be undone.')) { resetAll(); setMsg({ ok: true, text: 'All local data erased.' }); setTimeout(() => location.reload(), 300); } }}>Reset all data</button>
      </div>
      {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text}</p>}
    </section>
  );
}

export function Notifications() {
  const [prefs, setPrefs] = useState(loadNotify);
  const [perm, setPerm] = useState<Support>(notifySupport);
  const [msg, setMsg] = useState('');
  const set = (enabled: boolean) => { const p = { ...prefs, enabled }; setPrefs(p); saveNotify(p); };
  const toggle = async (on: boolean) => {
    if (!on) { set(false); setMsg('Notifications off.'); return; }
    const p = perm === 'granted' ? perm : await requestPermission();
    setPerm(p);
    if (p !== 'granted') { set(false); setMsg(p === 'denied' ? 'Notifications are blocked for this site. Allow them in your browser settings, then try again.' : p === 'unsupported' ? 'This browser does not support notifications.' : 'Permission was not granted.'); return; }
    set(true);
    const n = await checkReminders();
    setMsg(n ? `On. ${n} reminder${n === 1 ? '' : 's'} due now.` : 'On. You will be notified when you open the app and a reminder is due.');
  };
  return (
    <section className="card" id="notifications">
      <h2>Maintenance notifications</h2>
      {perm === 'unsupported' ? <p className="muted">This browser does not support notifications. Due reminders still show on Home and in the Garage.</p> : (
        <label className="check"><input type="checkbox" checked={prefs.enabled && perm === 'granted'} onChange={(e) => toggle(e.target.checked)} /><span>Notify me when a Garage reminder is due soon or overdue</span></label>
      )}
      {perm === 'denied' && <p className="warn-t">Blocked in browser settings.</p>}
      {msg && <p className="muted" role="status">{msg}</p>}
      <p className="note">Checked on this device each time you open the app — there is no server and no background push, so nothing arrives while the app is closed. Each due point is announced once.</p>
    </section>
  );
}

export default function Settings() {
  const { settings, setSettings } = useSettings();
  const t = useT();
  const { hash } = useLocation();
  const nav = useNavigate();
  useEffect(() => { if (hash) document.getElementById(hash.slice(1))?.scrollIntoView(); }, [hash]);
  return (
    <>
      <h1>{t('settings.title')}</h1>
      <section className="card">
        <h2>{t('settings.units')}</h2>
        <Seg<Units> label={t('settings.units')} value={settings.units} options={[['imperial', t('settings.imperial')], ['metric', t('settings.metric')]]} onChange={(units) => setSettings({ ...settings, units })} />
        <Note>{t('settings.unitsNote')}</Note>
      </section>
      <section className="card">
        <h2>{t('settings.theme')}</h2>
        <Seg<ThemePref> label={t('settings.theme')} value={settings.theme} options={[['dark', t('settings.dark')], ['light', t('settings.light')], ['system', t('settings.system')]]} onChange={(theme) => setSettings({ ...settings, theme })} />
      </section>
      <section className="card" id="language">
        <h2>{t('settings.language')}</h2>
        <Seg<Lang> label={t('settings.language')} value={settings.lang} options={LANGS.map(([v, l]) => [v, l])} onChange={(lang) => setSettings({ ...settings, lang })} />
        <Note>{t('settings.languageNote')}</Note>
      </section>
      <section className="card">
        <h2>{t('settings.intro')}</h2>
        <p className="muted">{t('settings.introText')}</p>
        <button className="btn ghost" onClick={() => { saveOnboarding({ done: false, completed: '' }); nav('/welcome'); }}>{t('settings.introBtn')}</button>
      </section>
      <Notifications />
      <DataManagement />
      <p className="muted small">{t('settings.carLink')} <Link to="/garage">{t('nav.garage')} →</Link></p>
    </>
  );
}
