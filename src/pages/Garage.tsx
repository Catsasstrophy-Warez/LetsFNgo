import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { decodeVin } from '../lib/vin';
import { colors } from '../data/colors';
import { CarArt } from '../components/CarArt';
import { Note } from '../components/Facts';
import {
  EMPTY_GARAGE, KEYS, loadGarage, loadPlans, loadTrack, reminderStatus, saveGarage, toNum, today, uid,
  type GarageState, type LogEntry, type Reminder,
} from '../lib/garage';
import { makeBackup, parseBackup } from '../lib/backup';
import { save } from '../lib/storage';
import { formatLapTime, lapStats, parseLaps } from '../lib/laptime';
import { drawShareCard } from '../lib/shareCard';

function Log({ title, items, onAdd, onDelete }: { title: string; items: LogEntry[]; onAdd: (e: LogEntry) => void; onDelete: (id: string) => void }) {
  const [f, setF] = useState({ date: today(), title: '', notes: '', miles: '', cost: '' });
  return (
    <section className="card">
      <h2>{title}</h2>
      <form className="form" onSubmit={(e) => { e.preventDefault(); if (!f.title.trim()) return; onAdd({ id: uid(), ...f }); setF({ ...f, title: '', notes: '', miles: '', cost: '' }); }}>
        <input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} aria-label={`${title}: date`} />
        <input className="input" placeholder="What was done" value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} aria-label={`${title}: what was done`} />
        <input className="input" placeholder="Mileage" inputMode="numeric" value={f.miles} onChange={(e) => setF({ ...f, miles: e.target.value })} aria-label={`${title}: mileage`} />
        <input className="input" placeholder="Cost" inputMode="decimal" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} aria-label={`${title}: cost`} />
        <textarea className="input" placeholder="Notes" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} aria-label={`${title}: notes`} />
        <button className="btn" type="submit">Add</button>
      </form>
      {items.length === 0 ? <p className="muted">Nothing logged yet.</p> : (
        <ul className="rows">
          {[...items].sort((a, b) => b.date.localeCompare(a.date)).map((i) => (
            <li key={i.id}>
              <div className="row-main"><span><strong>{i.title}</strong> <span className="muted">{i.date}{i.miles && ` · ${i.miles} mi`}{i.cost && ` · $${i.cost}`}</span></span>
                <button className="link-btn" onClick={() => onDelete(i.id)} aria-label={`Delete ${i.title}`}>Delete</button></div>
              {i.notes && <p className="wrap">{i.notes}</p>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

const STATE_LABEL = { overdue: 'Overdue', soon: 'Due soon', ok: 'OK', unknown: 'Set last service' } as const;

function Reminders({ g, setG }: { g: GarageState; setG: React.Dispatch<React.SetStateAction<GarageState>> }) {
  const odo = toNum(g.odometer);
  const now = today();
  const upd = (id: string, patch: Partial<Reminder>) => setG((s) => ({ ...s, reminders: s.reminders.map((r) => (r.id === id ? { ...r, ...patch } : r)) }));
  const n = (v: string) => toNum(v);
  return (
    <section className="card" id="maintenance">
      <h2>Maintenance reminders</h2>
      <label className="form-label">Current odometer (mi)<input className="input" inputMode="numeric" value={g.odometer} onChange={(e) => setG({ ...g, odometer: e.target.value })} /></label>
      <Note>Intervals are <strong>user-set</strong>. The defaults are placeholders, not Ford's schedule — the 2020–22 GT500 service intervals are not sourced in this app. Check your owner's manual and oil-life monitor. <Link to="/ownership">Fluids &amp; specs →</Link></Note>
      <ul className="rows">
        {g.reminders.map((r) => {
          const st = reminderStatus(r, odo, now);
          return (
            <li key={r.id}>
              <div className="row-main">
                <input className="input inline" value={r.item} onChange={(e) => upd(r.id, { item: e.target.value })} aria-label="Service item" />
                <span className={`due due-${st.state}`}>{STATE_LABEL[st.state]}</span>
              </div>
              <div className="form four">
                <label>Every (mi)<input className="input" inputMode="numeric" value={r.everyMiles ?? ''} onChange={(e) => upd(r.id, { everyMiles: n(e.target.value) })} /></label>
                <label>Every (months)<input className="input" inputMode="numeric" value={r.everyMonths ?? ''} onChange={(e) => upd(r.id, { everyMonths: n(e.target.value) })} /></label>
                <label>Last done (mi)<input className="input" inputMode="numeric" value={r.lastMiles ?? ''} onChange={(e) => upd(r.id, { lastMiles: n(e.target.value) })} /></label>
                <label>Last done (date)<input className="input" type="date" value={r.lastDate} onChange={(e) => upd(r.id, { lastDate: e.target.value })} /></label>
              </div>
              <p className="muted small">
                {st.dueMiles !== null && <>Due at {st.dueMiles.toLocaleString('en-US')} mi{st.milesLeft !== null && ` (${st.milesLeft >= 0 ? `${st.milesLeft.toLocaleString('en-US')} to go` : `${(-st.milesLeft).toLocaleString('en-US')} over`})`}. </>}
                {st.dueDate && <>Due by {st.dueDate}{st.daysLeft !== null && ` (${st.daysLeft >= 0 ? `${st.daysLeft} days` : `${-st.daysLeft} days late`})`}. </>}
                <button className="link-btn" onClick={() => upd(r.id, { lastDate: now, lastMiles: odo ?? r.lastMiles })}>Mark done today</button>{' · '}
                <button className="link-btn danger" onClick={() => setG((s) => ({ ...s, reminders: s.reminders.filter((x) => x.id !== r.id) }))} aria-label={`Remove ${r.item}`}>Remove</button>
              </p>
            </li>
          );
        })}
      </ul>
      <button className="btn ghost" onClick={() => setG((s) => ({ ...s, reminders: [...s.reminders, { id: uid(), item: 'New item', everyMiles: null, everyMonths: 12, lastMiles: null, lastDate: '' }] }))}>Add reminder</button>
    </section>
  );
}

function ShareCard({ g }: { g: GarageState }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const color = colors.find((c) => c.id === g.color);
  const sessions = loadTrack();
  let bestLap = '', bestLapTrack = '', best = Infinity;
  for (const s of sessions) { const b = lapStats(parseLaps(s.laps).laps).best; if (b !== null && b < best) { best = b; bestLap = formatLapTime(b); bestLapTrack = s.track; } }
  const data = { title: g.nickname || 'My GT500', year: g.year, colorName: color?.name ?? (g.color === 'other' ? 'Other' : ''), swatch: color?.swatch ?? '#c8102e', modsCount: g.mods.length, bestLap, bestLapTrack };
  const key = JSON.stringify(data);
  useEffect(() => { if (ref.current) drawShareCard(ref.current, JSON.parse(key)); }, [key]);
  const download = () => {
    const c = ref.current; if (!c) return;
    const a = document.createElement('a');
    a.href = c.toDataURL('image/png'); a.download = 'gt500-spec-card.png'; a.click();
  };
  return (
    <section className="card">
      <h2>Spec-sheet share card</h2>
      <canvas ref={ref} className="share-canvas" width={1080} height={1080} role="img" aria-label={`Share card: ${data.title}, ${data.year || 'year not set'}, ${data.colorName || 'color not set'}, ${data.modsCount} mods, best lap ${bestLap || 'none'}`} />
      <button className="btn" onClick={download}>Download PNG</button>
      <Note>Generic silhouette, no logos. Uses your nickname, year, color, mods count and best logged lap.</Note>
    </section>
  );
}

function Backup({ setG }: { setG: (g: GarageState) => void }) {
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const exportAll = () => {
    const b = makeBackup(loadGarage(), loadPlans(), loadTrack());
    const url = URL.createObjectURL(new Blob([JSON.stringify(b, null, 2)], { type: 'application/json' }));
    const a = document.createElement('a'); a.href = url; a.download = `gt500-companion-backup-${today()}.json`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setMsg({ ok: true, text: 'Backup downloaded.' });
  };
  const importFile = async (file: File) => {
    const r = parseBackup(await file.text());
    if (!r.ok) return setMsg({ ok: false, text: `Import failed: ${r.errors.slice(0, 4).join('; ')}` });
    if (!confirm('Replace Garage, build plans and track sessions on this device with the backup?')) return;
    saveGarage(r.data.garage); save(KEYS.plans, r.data.plans); save(KEYS.track, r.data.track);
    setG(r.data.garage);
    setMsg({ ok: true, text: `Imported ${r.data.plans.length} plan(s) and ${r.data.track.length} session(s).` });
  };
  return (
    <section className="card">
      <h2>Backup &amp; restore</h2>
      <p className="muted">Exports Garage, maintenance reminders, build plans and track sessions as one JSON file (schema v1).</p>
      <div className="btn-row">
        <button className="btn" onClick={exportAll}>Export JSON</button>
        <label className="btn ghost file-btn">Import JSON<input type="file" accept="application/json,.json" className="sr-only" onChange={(e) => { const f = e.target.files?.[0]; if (f) importFile(f); e.target.value = ''; }} /></label>
      </div>
      {msg && <p className={msg.ok ? 'ok-t' : 'err'} role="status">{msg.text}</p>}
    </section>
  );
}

export default function Garage() {
  const [g, setG] = useState<GarageState>(loadGarage);
  useEffect(() => saveGarage(g), [g]);
  const d = g.vin ? decodeVin(g.vin) : null;
  const swatch = colors.find((c) => c.id === g.color)?.swatch;

  const setVin = (vin: string) => {
    const dec = decodeVin(vin);
    setG((s) => ({ ...s, vin, year: dec.year && !s.year ? String(dec.year) : s.year }));
  };

  return (
    <>
      <h1>My Garage</h1>
      <p className="muted">Stored only on this device (localStorage). Clearing site data erases it — use Backup below.</p>
      <section className="card">
        <CarArt body={swatch} />
        <div className="form">
          <label>Nickname<input className="input" value={g.nickname} onChange={(e) => setG({ ...g, nickname: e.target.value })} /></label>
          <label>VIN<input className="input mono" value={g.vin} maxLength={17} onChange={(e) => setVin(e.target.value.toUpperCase())} /></label>
          {d && <p className={d.valid && d.isGT500 ? 'ok-t' : 'warn-t'}>{!d.valid ? d.errors[0] : d.isGT500 ? `Valid ${d.year} GT500 VIN pattern` : 'Valid VIN, but not a 2020–22 GT500 pattern'}</p>}
          <label>Model year
            <select className="input" value={g.year} onChange={(e) => setG({ ...g, year: e.target.value })}>
              <option value="">—</option><option>2020</option><option>2021</option><option>2022</option>
            </select>
          </label>
          <label>Color
            <select className="input" value={g.color} onChange={(e) => setG({ ...g, color: e.target.value })}>
              <option value="">—</option>
              {colors.filter((c) => !g.year || c.years.includes(Number(g.year) as 2020)).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              <option value="other">Other / not listed</option>
            </select>
          </label>
        </div>
      </section>
      <Reminders g={g} setG={setG} />
      <Log title="Mods log" items={g.mods} onAdd={(e) => setG((s) => ({ ...s, mods: [...s.mods, e] }))} onDelete={(id) => setG((s) => ({ ...s, mods: s.mods.filter((m) => m.id !== id) }))} />
      <Log title="Service log" items={g.service} onAdd={(e) => setG((s) => ({ ...s, service: [...s.service, e] }))} onDelete={(id) => setG((s) => ({ ...s, service: s.service.filter((m) => m.id !== id) }))} />
      <ShareCard g={g} />
      <Backup setG={setG} />
      <button className="link-btn danger" onClick={() => { if (confirm('Erase all garage data on this device?')) setG(EMPTY_GARAGE); }}>Reset garage</button>
    </>
  );
}
