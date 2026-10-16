import { useEffect, useState } from 'react';
import { load, save } from '../lib/storage';
import { decodeVin } from '../lib/vin';
import { colors } from '../data/colors';
import { CarArt } from '../components/CarArt';

interface LogEntry { id: string; date: string; title: string; notes: string; miles?: string; cost?: string }
interface GarageState { vin: string; year: string; color: string; nickname: string; mods: LogEntry[]; service: LogEntry[] }

const KEY = 'gt500.garage.v1';
const EMPTY: GarageState = { vin: '', year: '', color: '', nickname: '', mods: [], service: [] };
const uid = () => Math.random().toString(36).slice(2, 10);

function Log({ title, items, onAdd, onDelete }: { title: string; items: LogEntry[]; onAdd: (e: LogEntry) => void; onDelete: (id: string) => void }) {
  const [f, setF] = useState({ date: new Date().toISOString().slice(0, 10), title: '', notes: '', miles: '', cost: '' });
  return (
    <section className="card">
      <h2>{title}</h2>
      <form className="form" onSubmit={(e) => { e.preventDefault(); if (!f.title.trim()) return; onAdd({ id: uid(), ...f }); setF({ ...f, title: '', notes: '', miles: '', cost: '' }); }}>
        <input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} aria-label="Date" />
        <input className="input" placeholder="What was done" value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} aria-label="Title" />
        <input className="input" placeholder="Mileage" inputMode="numeric" value={f.miles} onChange={(e) => setF({ ...f, miles: e.target.value })} aria-label="Mileage" />
        <input className="input" placeholder="Cost" inputMode="decimal" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} aria-label="Cost" />
        <textarea className="input" placeholder="Notes" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} aria-label="Notes" />
        <button className="btn" type="submit">Add</button>
      </form>
      {items.length === 0 ? <p className="muted">Nothing logged yet.</p> : (
        <ul className="rows">
          {[...items].sort((a, b) => b.date.localeCompare(a.date)).map((i) => (
            <li key={i.id}>
              <div className="row-main"><span><strong>{i.title}</strong> <span className="muted">{i.date}{i.miles && ` · ${i.miles} mi`}{i.cost && ` · $${i.cost}`}</span></span>
                <button className="link-btn" onClick={() => onDelete(i.id)} aria-label={`Delete ${i.title}`}>Delete</button></div>
              {i.notes && <p>{i.notes}</p>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export default function Garage() {
  const [g, setG] = useState<GarageState>(() => ({ ...EMPTY, ...load<Partial<GarageState>>(KEY, {}) }));
  useEffect(() => save(KEY, g), [g]);
  const d = g.vin ? decodeVin(g.vin) : null;
  const swatch = colors.find((c) => c.id === g.color)?.swatch;

  const setVin = (vin: string) => {
    const dec = decodeVin(vin);
    setG((s) => ({ ...s, vin, year: dec.year && !s.year ? String(dec.year) : s.year }));
  };

  return (
    <>
      <h1>My Garage</h1>
      <p className="muted">Stored only on this device (localStorage). Clearing site data erases it.</p>
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
      <Log title="Mods log" items={g.mods} onAdd={(e) => setG((s) => ({ ...s, mods: [...s.mods, e] }))} onDelete={(id) => setG((s) => ({ ...s, mods: s.mods.filter((m) => m.id !== id) }))} />
      <Log title="Service log" items={g.service} onAdd={(e) => setG((s) => ({ ...s, service: [...s.service, e] }))} onDelete={(id) => setG((s) => ({ ...s, service: s.service.filter((m) => m.id !== id) }))} />
      <button className="link-btn danger" onClick={() => { if (confirm('Erase all garage data on this device?')) setG(EMPTY); }}>Reset garage</button>
    </>
  );
}
