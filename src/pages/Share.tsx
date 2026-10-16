import { useState } from 'react';
import { Link, useParams } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { decodeShare } from '../lib/share';
import { summarizePlan } from '../lib/planner';
import { KEYS, loadGarage, loadPlans, saveGarage, today, uid } from '../lib/garage';
import { save } from '../lib/storage';
import { colors } from '../data/colors';

const money = (n: number) => `$${Math.round(n).toLocaleString('en-US')}`;

/** Read-only view of a shared plan or car summary (#/share/<payload>). Nothing is saved until "Import". */
export default function Share() {
  const { data = '' } = useParams();
  const r = decodeShare(data);
  const [msg, setMsg] = useState('');
  if (!r.ok) return (<><h1>Shared link</h1><p className="err" role="alert">{r.error}</p><p><Link to="/">Go home →</Link></p></>);
  const d = r.data;

  if (d.k === 'plan') {
    const sum = summarizePlan(d.modIds);
    const importPlan = () => {
      const plans = loadPlans();
      if (save(KEYS.plans, [...plans, { id: uid(), name: `${d.name} (shared)`, modIds: d.modIds, created: today() }])) setMsg('Plan added to your Build Planner.');
      else setMsg('This device refused to save the plan.');
    };
    return (
      <>
        <h1>Shared build plan</h1>
        <p className="lede">Read-only. Nothing is saved until you import it.</p>
        <section className="card">
          <h2>{d.name}</h2>
          <p className="stat-v">{sum.pricedCount ? (sum.costMin === sum.costMax ? money(sum.costMin) : `${money(sum.costMin)}–${money(sum.costMax)}`) : '—'}<small>parts, sourced prices</small></p>
          {sum.unpricedCount > 0 && <p className="warn-t">{sum.unpricedCount} mod{sum.unpricedCount === 1 ? ' has' : 's have'} no sourced price.</p>}
          <ul className="rows">{sum.mods.map((m) => <li key={m.id}><div className="sub">{m.stage}</div><p>{m.result}</p><Cite c={m.confidence} url={m.source} /></li>)}</ul>
          <button className="btn" onClick={importPlan}>Import to my Build Planner</button>
          {msg && <p className="ok-t" role="status">{msg} <Link to="/planner">Open planner →</Link></p>}
        </section>
        <Note>Gains are per source and not additive.</Note>
      </>
    );
  }

  const swatch = colors.find((c) => c.id === d.color);
  const importCar = () => {
    const g = loadGarage();
    if (!confirm('Add this car summary to your Garage? Empty year, color and nickname are filled; mods are added to the log; nothing is overwritten.')) return;
    const ok = saveGarage({
      ...g, year: g.year || d.year, color: g.color || d.color, nickname: g.nickname || d.nickname,
      mods: [...g.mods, ...d.mods.map((title) => ({ id: uid(), date: today(), title, notes: 'Imported from a shared link', miles: '', cost: '' }))],
    });
    setMsg(ok ? 'Imported to your Garage.' : 'This device refused to save.');
  };
  return (
    <>
      <h1>Shared car</h1>
      <p className="lede">Read-only. Nothing is saved until you import it. Shared links never include a VIN.</p>
      <section className="card">
        <h2>{swatch && <span className="dot" style={{ background: swatch.swatch }} aria-hidden />} {d.nickname || 'GT500'}</h2>
        <p className="muted">{[d.year, swatch?.name].filter(Boolean).join(' · ') || 'Year and color not shared'}</p>
        <div className="sub">Mods ({d.mods.length})</div>
        {d.mods.length ? <ul className="rows">{d.mods.map((m, i) => <li key={i}>{m}</li>)}</ul> : <p className="muted">Stock</p>}
        <button className="btn" onClick={importCar}>Import to my Garage</button>
        {msg && <p className="ok-t" role="status">{msg} <Link to="/garage">Open Garage →</Link></p>}
      </section>
    </>
  );
}
