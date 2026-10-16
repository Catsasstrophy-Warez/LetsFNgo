import { useEffect, useRef, useState } from 'react';
import { partsForReminder } from '../data/parts';
import { Link } from 'react-router';
import { decodeVin } from '../lib/vin';
import { colors } from '../data/colors';
import { CarArt } from '../components/CarArt';
import { Note } from '../components/Facts';
import {
  MAX_CARS, activeCarId, addCar, carLabel, forCar, loadCars, loadGarage, loadTrack, reminderStatus, saveGarage, toNum, today, uid,
  type GarageState, type LogEntry, type Reminder,
} from '../lib/garage';
import { UnitInput } from '../components/UnitInput';
import { useT, useUnits } from '../components/SettingsContext';
import { useCar } from '../components/CarContext';
import { fmtQty } from '../lib/units';
import { loadDrag } from '../lib/drag';
import { loadFuel } from '../lib/fuel';
import { loadDyno } from '../lib/dyno';
import { EtTrend, LapTrend } from '../components/Trends';
import { formatLapTime, lapStats, parseLaps } from '../lib/laptime';
import { drawShareCard } from '../lib/shareCard';
import { ShareLink } from '../components/ShareLink';
import { carLogCounts, deleteCar } from '../lib/carlog';
import { remindersToIcs } from '../lib/ics';
import { downloadText } from '../lib/download';

function Log({ title, items, onAdd, onDelete }: { title: string; items: LogEntry[]; onAdd: (e: LogEntry) => void; onDelete: (id: string) => void }) {
  const u = useUnits();
  const t = useT();
  const [f, setF] = useState({ date: today(), title: '', notes: '', miles: '', cost: '' });
  return (
    <section className="card">
      <h2>{title}</h2>
      <form className="form" onSubmit={(e) => { e.preventDefault(); if (!f.title.trim()) return; onAdd({ id: uid(), ...f }); setF({ ...f, title: '', notes: '', miles: '', cost: '' }); }}>
        <input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} aria-label={`${title}: ${t('log.date')}`} />
        <input className="input" placeholder={t('log.what')} value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} aria-label={`${title}: ${t('log.what')}`} />
        <UnitInput label={`${title}: ${t('log.odometer')}`} kind="distance" value={toNum(f.miles)} onChange={(v) => setF({ ...f, miles: v === null ? '' : String(Math.round(v)) })} digits={0} />
        <input className="input" placeholder={t('log.cost')} inputMode="decimal" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} aria-label={`${title}: ${t('log.cost')}`} />
        <textarea className="input" placeholder={t('log.notes')} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} aria-label={`${title}: ${t('log.notes')}`} />
        <button className="btn" type="submit">{t('common.add')}</button>
      </form>
      {items.length === 0 ? <p className="muted">{t('log.empty')}</p> : (
        <ul className="rows">
          {[...items].sort((a, b) => b.date.localeCompare(a.date)).map((i) => (
            <li key={i.id}>
              <div className="row-main"><span><strong>{i.title}</strong> <span className="muted">{i.date}{toNum(i.miles ?? '') !== null && ` · ${fmtQty('distance', toNum(i.miles ?? ''), u)}`}{i.cost && ` · $${i.cost}`}</span></span>
                <button className="link-btn" onClick={() => onDelete(i.id)} aria-label={t('common.deleteX', { x: i.title })}>{t('common.delete')}</button></div>
              {i.notes && <p className="wrap">{i.notes}</p>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

const STATE_KEY = { overdue: 'due.overdue', soon: 'due.soon', ok: 'due.ok', unknown: 'due.unknown' } as const;

function Reminders({ g, setG }: { g: GarageState; setG: React.Dispatch<React.SetStateAction<GarageState>> }) {
  const t = useT();
  const [icsMsg, setIcsMsg] = useState('');
  const odo = toNum(g.odometer);
  const now = today();
  const upd = (id: string, patch: Partial<Reminder>) => setG((s) => ({ ...s, reminders: s.reminders.map((r) => (r.id === id ? { ...r, ...patch } : r)) }));
  const n = (v: string) => toNum(v);
  const exportIcs = (all: boolean) => {
    const s = loadCars();
    const cars = (all ? s.cars : s.cars.filter((c) => c.id === activeCarId())).map((c) => ({ id: c.id, label: carLabel(c, s.cars.indexOf(c)), odometer: toNum(c.odometer), reminders: c.id === activeCarId() ? g.reminders : c.reminders }));
    const r = remindersToIcs(cars, now);
    if (!r.events) { setIcsMsg(t('ics.none')); return; }
    downloadText(r.ics, `gt500-maintenance-${now}.ics`, 'text/calendar;charset=utf-8');
    setIcsMsg(t('ics.done', { n: r.events }) + (r.skipped.length ? ` ${t('ics.skipped', { n: r.skipped.length })}` : ''));
  };
  return (
    <section className="card" id="maintenance">
      <h2>{t('garage.reminders')}</h2>
      <div className="form-label"><UnitInput label={t('garage.odometer')} kind="distance" value={odo} onChange={(v) => setG({ ...g, odometer: v === null ? '' : String(Math.round(v)) })} digits={0} /></div>
      <Note>{t('garage.remindersNote')} <span className="badge badge-reported">reported</span> <Link to="/ownership">{t('garage.fluidsLink')}</Link> · <Link to="/parts">{t('garage.partsLink')}</Link> · <Link to="/guides/track-service">{t('garage.trackGuideLink')}</Link></Note>
      <ul className="rows">
        {g.reminders.map((r) => {
          const st = reminderStatus(r, odo, now);
          return (
            <li key={r.id}>
              <div className="row-main">
                <input className="input inline" value={r.item} onChange={(e) => upd(r.id, { item: e.target.value })} aria-label={t('garage.item')} />
                <span className={`due due-${st.state}`}>{t(STATE_KEY[st.state])}</span>
              </div>
              <div className="form four">
                <UnitInput label={t('garage.every')} kind="distance" value={r.everyMiles} onChange={(v) => upd(r.id, { everyMiles: v === null ? null : Math.round(v) })} digits={0} />
                <label>{t('garage.everyMonths')}<input className="input" inputMode="numeric" value={r.everyMonths ?? ''} onChange={(e) => upd(r.id, { everyMonths: n(e.target.value) })} /></label>
                <UnitInput label={t('garage.lastDone')} kind="distance" value={r.lastMiles} onChange={(v) => upd(r.id, { lastMiles: v === null ? null : Math.round(v) })} digits={0} />
                <label>{t('garage.lastDate')}<input className="input" type="date" value={r.lastDate} onChange={(e) => upd(r.id, { lastDate: e.target.value })} /></label>
              </div>
              <p className="muted small">
                {st.dueMiles !== null && <>{t('garage.dueAt', { mi: st.dueMiles.toLocaleString('en-US') })}{st.milesLeft !== null && ` (${st.milesLeft >= 0 ? t('garage.toGo', { n: st.milesLeft.toLocaleString('en-US') }) : t('garage.over', { n: (-st.milesLeft).toLocaleString('en-US') })})`}. </>}
                {st.dueDate && <>{t('garage.dueBy', { d: st.dueDate })}{st.daysLeft !== null && ` (${st.daysLeft >= 0 ? t('garage.days', { n: st.daysLeft }) : t('garage.daysLate', { n: -st.daysLeft })})`}. </>}
                {partsForReminder(r.id).filter((p) => p.kind !== 'avoid').length > 0 && <>{t('garage.parts')} {partsForReminder(r.id).filter((p) => p.kind !== 'avoid').map((p, i) => <span key={p.id}>{i ? ', ' : ''}<Link to={`/parts?q=${encodeURIComponent(p.number)}`} className="mono">{p.number}</Link></span>)}. </>}
                <button className="link-btn" onClick={() => upd(r.id, { lastDate: now, lastMiles: odo ?? r.lastMiles })}>{t('garage.markDone')}</button>{' · '}
                <button className="link-btn danger" onClick={() => setG((s) => ({ ...s, reminders: s.reminders.filter((x) => x.id !== r.id) }))} aria-label={t('common.removeX', { x: r.item })}>{t('common.remove')}</button>
              </p>
            </li>
          );
        })}
      </ul>
      <div className="btn-row">
        <button className="btn ghost" onClick={() => setG((s) => ({ ...s, reminders: [...s.reminders, { id: uid(), item: t('garage.newItem'), everyMiles: null, everyMonths: 12, lastMiles: null, lastDate: '' }] }))}>{t('garage.addReminder')}</button>
        <button className="btn ghost" onClick={() => exportIcs(false)}>{t('ics.export')}</button>
        {loadCars().cars.length > 1 && <button className="btn ghost" onClick={() => exportIcs(true)}>{t('ics.exportAll')}</button>}
      </div>
      {icsMsg && <p className="muted small" role="status">{icsMsg}</p>}
      <p className="note">{t('ics.note')}</p>
    </section>
  );
}

function ShareCard({ g }: { g: GarageState }) {
  const t = useT();
  const ref = useRef<HTMLCanvasElement>(null);
  const color = colors.find((c) => c.id === g.color);
  const sessions = forCar(loadTrack(), activeCarId());
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
      <h2>{t('share.cardTitle')}</h2>
      <canvas ref={ref} className="share-canvas" width={1080} height={1080} role="img" aria-label={t('share.cardAlt', { title: data.title, year: data.year || t('share.noYear'), color: data.colorName || t('share.noColor'), mods: data.modsCount, lap: bestLap || t('share.noLap') })} />
      <button className="btn" onClick={download}>{t('share.png')}</button>
      <Note>{t('share.cardNote')}</Note>
      <h3>{t('share.asLink')}</h3>
      <ShareLink label={t('share.createCar')} payload={{ v: 1, k: 'car', year: (['2020', '2021', '2022'].includes(g.year) ? g.year : '') as '', color: g.color, nickname: g.nickname, mods: g.mods.map((m) => m.title) }} />
      <Note>{t('share.linkNote')}</Note>
    </section>
  );
}

/** List, add, switch and delete cars. */
function Cars() {
  const t = useT();
  const car = useCar();
  const [msg, setMsg] = useState('');
  const add = () => {
    const id = addCar();
    if (!id) { setMsg(t('cars.limit', { n: MAX_CARS })); return; }
    car.switchCar(id);
  };
  const del = () => {
    const s = loadCars();
    const i = s.cars.findIndex((c) => c.id === car.active);
    const c = carLogCounts(car.active, { track: loadTrack(), drag: loadDrag(), fuel: loadFuel(), dyno: loadDyno() });
    if (!confirm(t('cars.confirmDelete', { name: carLabel(s.cars[i], i), track: c.track, drag: c.drag, fuel: c.fuel, dyno: c.dyno }))) return;
    if (deleteCar(car.active)) car.switchCar(loadCars().active);
    else setMsg(t('cars.deleteFailed'));
  };
  return (
    <section className="card" aria-labelledby="cars-h">
      <h2 id="cars-h">{t('cars.title')}</h2>
      {car.cars.length > 1 && (
        <div role="radiogroup" aria-label={t('car.switch')} className="seg wrap-seg">
          {car.cars.map((c) => <button key={c.id} role="radio" aria-checked={c.id === car.active} className={c.id === car.active ? 'on' : ''} onClick={() => car.switchCar(c.id)}>{c.label}</button>)}
        </div>
      )}
      <p className="muted small">{t('cars.note')}</p>
      <div className="btn-row">
        <button className="btn ghost" onClick={add}>{t('cars.add')}</button>
        {car.cars.length > 1 && <button className="btn ghost danger-btn" onClick={del}>{t('cars.delete')}</button>}
      </div>
      {msg && <p className="err" role="status">{msg}</p>}
    </section>
  );
}

export default function Garage() {
  const t = useT();
  const { refresh } = useCar();
  const [g, setG] = useState<GarageState>(loadGarage);
  useEffect(() => { saveGarage(g); refresh(); }, [g, refresh]);
  const d = g.vin ? decodeVin(g.vin) : null;
  const swatch = colors.find((c) => c.id === g.color)?.swatch;
  const id = activeCarId();

  const setVin = (vin: string) => {
    const dec = decodeVin(vin);
    setG((s) => ({ ...s, vin, year: dec.year && !s.year ? String(dec.year) : s.year }));
  };

  return (
    <>
      <h1>{t('garage.title')}</h1>
      <p className="muted">{t('garage.storedNote')} <Link to="/settings#data">{t('nav.settings')}</Link>.</p>
      <Cars />
      <section className="card">
        <CarArt body={swatch} />
        <div className="form">
          <label>{t('garage.nickname')}<input className="input" value={g.nickname} onChange={(e) => setG({ ...g, nickname: e.target.value })} /></label>
          <label>VIN<input className="input mono" value={g.vin} maxLength={17} onChange={(e) => setVin(e.target.value.toUpperCase())} /></label>
          {d && <p className={d.valid && d.isGT500 ? 'ok-t' : 'warn-t'}>{!d.valid ? d.errors[0] : d.isGT500 ? t('garage.vinOk', { year: d.year ?? '' }) : t('garage.vinNotGt500')}</p>}
          <label>{t('garage.year')}
            <select className="input" value={g.year} onChange={(e) => setG({ ...g, year: e.target.value })}>
              <option value="">—</option><option>2020</option><option>2021</option><option>2022</option>
            </select>
          </label>
          <label>{t('garage.color')}
            <select className="input" value={g.color} onChange={(e) => setG({ ...g, color: e.target.value })}>
              <option value="">—</option>
              {colors.filter((c) => !g.year || c.years.includes(Number(g.year) as 2020)).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              <option value="other">{t('garage.otherColor')}</option>
            </select>
          </label>
        </div>
      </section>
      <Reminders g={g} setG={setG} />
      <Log title={t('garage.modsLog')} items={g.mods} onAdd={(e) => setG((s) => ({ ...s, mods: [...s.mods, e] }))} onDelete={(x) => setG((s) => ({ ...s, mods: s.mods.filter((m) => m.id !== x) }))} />
      <Log title={t('garage.serviceLog')} items={g.service} onAdd={(e) => setG((s) => ({ ...s, service: [...s.service, e] }))} onDelete={(x) => setG((s) => ({ ...s, service: s.service.filter((m) => m.id !== x) }))} />
      <section className="card">
        <h2>{t('report.cardTitle')}</h2>
        <p className="muted">{t('report.cardText')}</p>
        <Link className="btn ghost" to="/report">{t('report.open')}</Link>
      </section>
      <ShareCard g={g} />
      <section className="card">
        <h2>{t('garage.trends')}</h2>
        <LapTrend sessions={forCar(loadTrack(), id)} />
        <EtTrend slips={forCar(loadDrag(), id).sort((a, b) => a.date.localeCompare(b.date))} />
        <p className="small"><Link to="/track">{t('nav.track')} →</Link> · <Link to="/drag">{t('nav.drag')} →</Link> · <Link to="/fuel">{t('nav.fuel')} →</Link> · <Link to="/achievements">{t('nav.achievements')} →</Link></p>
      </section>
      <section className="card">
        <h2>{t('garage.backupTitle')}</h2>
        <p className="muted">{t('garage.backupText')}</p>
        <Link className="btn ghost" to="/settings#data">{t('garage.backupLink')}</Link>
      </section>
    </>
  );
}
