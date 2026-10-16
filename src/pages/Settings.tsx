import { useEffect, useState } from 'react';
import { downloadText } from '../lib/download';
import { Link, useLocation, useNavigate } from 'react-router';
import { saveOnboarding } from '../lib/onboarding';
import { useSettings, useT } from '../components/SettingsContext';
import { useCar } from '../components/CarContext';
import { GO } from '../lib/shortcuts';
import type { MsgKey } from '../lib/i18n';
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
  const t = useT();
  const { refresh } = useCar();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const exportAll = () => {
    downloadText(JSON.stringify(currentBackup(), null, 2), `gt500-companion-backup-${today()}.json`, 'application/json');
    setMsg({ ok: true, text: t('data.downloaded') });
  };
  const importFile = async (file: File) => {
    if (file.size > MAX_IMPORT_BYTES) return setMsg({ ok: false, text: t('data.tooBig', { mb: MAX_IMPORT_BYTES / 1024 / 1024 }) });
    const r = parseBackup(await file.text());
    if (!r.ok) return setMsg({ ok: false, text: t('data.failed', { e: r.errors.slice(0, 4).join('; ') }) });
    if (!confirm(t('data.confirm'))) return;
    if (!restoreBackup(r.data)) return setMsg({ ok: false, text: t('data.refused') });
    setSettings(r.data.settings);
    refresh();
    const d = r.data;
    setMsg({ ok: true, text: t('data.imported', { cars: d.cars.cars.length, plans: d.plans.length, track: d.track.length, drag: d.drag.length, fuel: d.fuel.length }) + (r.migratedFrom ? ` ${t('data.upgraded', { v: r.migratedFrom })}` : '') });
  };
  return (
    <section className="card" id="data">
      <h2>{t('data.title')}</h2>
      <p className="muted">{t('data.text', { v: SCHEMA_VERSION })}</p>
      <div className="btn-row">
        <button className="btn" onClick={exportAll}>{t('data.export')}</button>
        <label className="btn ghost file-btn">{t('data.import')}<input type="file" accept="application/json,.json" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; if (f) importFile(f); e.target.value = ''; }} /></label>
        <button className="btn ghost danger-btn" onClick={() => { if (confirm(t('data.resetConfirm'))) { resetAll(); setMsg({ ok: true, text: t('data.erased') }); setTimeout(() => location.reload(), 300); } }}>{t('data.reset')}</button>
      </div>
      {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text}</p>}
    </section>
  );
}

export function Notifications() {
  const t = useT();
  const [prefs, setPrefs] = useState(loadNotify);
  const [perm, setPerm] = useState<Support>(notifySupport);
  const [msg, setMsg] = useState('');
  const set = (enabled: boolean) => { const p = { ...prefs, enabled }; setPrefs(p); saveNotify(p); };
  const toggle = async (on: boolean) => {
    if (!on) { set(false); setMsg(t('notif.off')); return; }
    const p = perm === 'granted' ? perm : await requestPermission();
    setPerm(p);
    if (p !== 'granted') { set(false); setMsg(p === 'denied' ? t('notif.blockedMsg') : p === 'unsupported' ? t('notif.unsupportedShort') : t('notif.notGranted')); return; }
    set(true);
    const n = await checkReminders();
    setMsg(n ? t('notif.onDue', { n }) : t('notif.on'));
  };
  return (
    <section className="card" id="notifications">
      <h2>{t('notif.title')}</h2>
      {perm === 'unsupported' ? <p className="muted">{t('notif.unsupported')}</p> : (
        <label className="check"><input type="checkbox" checked={prefs.enabled && perm === 'granted'} onChange={(e) => toggle(e.target.checked)} /><span>{t('notif.label')}</span></label>
      )}
      {perm === 'denied' && <p className="warn-t">{t('notif.blocked')}</p>}
      {msg && <p className="muted" role="status">{msg}</p>}
      <p className="note">{t('notif.note')}</p>
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
      <section className="card" id="shortcuts">
        <h2>{t('keys.title')}</h2>
        <p className="muted">{t('keys.settingsText')}</p>
        <ul className="rows small">
          <li><kbd>/</kbd> {t('keys.search')}</li><li><kbd>?</kbd> {t('keys.help')}</li>
          {Object.entries(GO).map(([k, v]) => <li key={k}><kbd>g</kbd> <kbd>{k}</kbd> {t('keys.goto', { page: t(v.key as MsgKey) })}</li>)}
        </ul>
      </section>
      <p className="muted small">{t('settings.carLink')} <Link to="/garage">{t('nav.garage')} →</Link></p>
    </>
  );
}
