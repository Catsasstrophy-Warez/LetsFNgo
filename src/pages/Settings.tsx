import { useEffect, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useSettings } from '../components/SettingsContext';
import { Note } from '../components/Facts';
import { MAX_IMPORT_BYTES, SCHEMA_VERSION, currentBackup, parseBackup, resetAll, restoreBackup } from '../lib/backup';
import { today } from '../lib/garage';
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
    if (!confirm('Replace Garage, plans, track sessions, timeslips, fill-ups and settings on this device with the backup?')) return;
    if (!restoreBackup(r.data)) return setMsg({ ok: false, text: 'Import failed: this device refused to save the data (storage full or blocked). Nothing may have been restored.' });
    setSettings(r.data.settings);
    const d = r.data;
    setMsg({ ok: true, text: `Imported ${d.plans.length} plan(s), ${d.track.length} session(s), ${d.drag.length} timeslip(s) and ${d.fuel.length} fill-up(s)${r.migratedFrom ? ` (upgraded from schema v${r.migratedFrom})` : ''}.` });
  };
  return (
    <section className="card" id="data">
      <h2>Data management</h2>
      <p className="muted">Everything is stored only on this device. Export writes one JSON file (schema v{SCHEMA_VERSION}) with Garage, reminders, build plans, track sessions, drag timeslips, fuel log and settings. Older v1 backups still import.</p>
      <div className="btn-row">
        <button className="btn" onClick={exportAll}>Export JSON</button>
        <label className="btn ghost file-btn">Import JSON<input type="file" accept="application/json,.json" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; if (f) importFile(f); e.target.value = ''; }} /></label>
        <button className="btn ghost danger-btn" onClick={() => { if (confirm('Erase ALL GT500 Companion data on this device? This cannot be undone.')) { resetAll(); setMsg({ ok: true, text: 'All local data erased.' }); setTimeout(() => location.reload(), 300); } }}>Reset all data</button>
      </div>
      {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text}</p>}
    </section>
  );
}

export default function Settings() {
  const { settings, setSettings } = useSettings();
  const { hash } = useLocation();
  useEffect(() => { if (hash) document.getElementById(hash.slice(1))?.scrollIntoView(); }, [hash]);
  return (
    <>
      <h1>Settings</h1>
      <section className="card">
        <h2>Units</h2>
        <Seg<Units> label="Units" value={settings.units} options={[['imperial', 'Imperial (mi, mph, lb, °F)'], ['metric', 'Metric (km, km/h, kg, °C)']]} onChange={(units) => setSettings({ ...settings, units })} />
        <Note>Applies to Specs, Gear &amp; Speed, Performance Tools, Garage, Drag Strip and Fuel logs and the print sheet. Data is stored in imperial units and converted for display, so switching never changes what you logged.</Note>
      </section>
      <section className="card">
        <h2>Theme</h2>
        <Seg<ThemePref> label="Theme" value={settings.theme} options={[['dark', 'Dark'], ['light', 'Light'], ['system', 'Match device']]} onChange={(theme) => setSettings({ ...settings, theme })} />
      </section>
      <DataManagement />
      <p className="muted small">Looking for your car? <Link to="/garage">Garage →</Link></p>
    </>
  );
}
