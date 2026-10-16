import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Cite, Note } from '../components/Facts';
import { save } from '../lib/storage';
import { KEYS, addModsToGarage, loadPlans, today, uid, type Plan } from '../lib/garage';
import { plannable, summarizePlan } from '../lib/planner';
import { warrantyNote } from '../data/mods';

const money = (n: number) => `$${Math.round(n).toLocaleString('en-US')}`;

export default function Planner() {
  const [plans, setPlans] = useState<Plan[]>(loadPlans);
  const [activeId, setActiveId] = useState<string>(() => loadPlans()[0]?.id ?? '');
  const [flash, setFlash] = useState('');
  useEffect(() => { save(KEYS.plans, plans); }, [plans]);
  const active = plans.find((p) => p.id === activeId) ?? null;
  const sum = summarizePlan(active?.modIds ?? []);

  const newPlan = () => {
    const p: Plan = { id: uid(), name: `Plan ${plans.length + 1}`, modIds: [], created: today() };
    setPlans([...plans, p]); setActiveId(p.id);
  };
  const update = (patch: Partial<Plan>) => setPlans((ps) => ps.map((p) => (p.id === activeId ? { ...p, ...patch } : p)));
  const toggle = (id: string) => active && update({ modIds: active.modIds.includes(id) ? active.modIds.filter((x) => x !== id) : [...active.modIds, id] });

  return (
    <>
      <h1>Build Planner</h1>
      <p className="lede">Pick sourced mods into a plan. Costs are summed only where a source lists a price. Horsepower figures are never combined.</p>
      <section className="card">
        <div className="form">
          <label>Plan
            <select className="input" value={activeId} onChange={(e) => setActiveId(e.target.value)}>
              {!plans.length && <option value="">No plans yet</option>}
              {plans.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          {active && <label>Plan name<input className="input" value={active.name} onChange={(e) => update({ name: e.target.value })} /></label>}
        </div>
        <div className="btn-row">
          <button className="btn" onClick={newPlan}>New plan</button>
          {active && <button className="btn ghost" onClick={() => { if (confirm(`Delete "${active.name}"?`)) { const rest = plans.filter((p) => p.id !== active.id); setPlans(rest); setActiveId(rest[0]?.id ?? ''); } }}>Delete plan</button>}
        </div>
      </section>
      {active && (
        <>
          <section className="card">
            <h2>Choose mods</h2>
            <ul className="rows">
              {plannable.map((m) => (
                <li key={m.id}>
                  <label className="check">
                    <input type="checkbox" checked={active.modIds.includes(m.id)} onChange={() => toggle(m.id)} />
                    <span><strong>{m.stage}</strong><br /><span className="muted">{m.parts}</span></span>
                  </label>
                </li>
              ))}
            </ul>
          </section>
          <section className="card hl" aria-live="polite">
            <h2>{active.name}: {sum.mods.length} mod{sum.mods.length === 1 ? '' : 's'}</h2>
            <p className="stat-v">{sum.pricedCount ? (sum.costMin === sum.costMax ? money(sum.costMin) : `${money(sum.costMin)}–${money(sum.costMax)}`) : '—'}<small>parts, sourced prices</small></p>
            {sum.unpricedCount > 0 && <p className="warn-t">{sum.unpricedCount} selected mod{sum.unpricedCount === 1 ? ' has' : 's have'} no sourced price, so the total is incomplete. Labor, tuning and fuel are not included.</p>}
            <ul className="rows">
              {sum.mods.map((m) => (
                <li key={m.id}>
                  <div className="sub">{m.stage}</div>
                  <p><strong>{m.result}</strong></p>
                  <div className="row-meta">{m.cost && <span className="tag">{m.cost.min === m.cost.max ? money(m.cost.min) : `${money(m.cost.min)}–${money(m.cost.max)}`}</span>}<Cite c={m.confidence} url={m.source} /></div>
                  {m.note && <Note>{m.note}</Note>}
                </li>
              ))}
            </ul>
            <Note>Each figure above comes from a different car, dyno, fuel and source. Gains are not additive and no combined horsepower is estimated.</Note>
            {sum.mods.length > 0 && (
              <button className="btn" onClick={() => { addModsToGarage(sum.mods.map((m) => ({ title: m.stage.replace(/^[\d·\s]+/, '') + ' (planned)', notes: `${m.parts}. From plan "${active.name}". Source: ${m.source}` }))); setFlash(`Added ${sum.mods.length} to the Garage mods log.`); }}>Add to Garage mods log</button>
            )}
            {flash && <p className="ok-t" role="status">{flash} <Link to="/garage">Open Garage →</Link></p>}
          </section>
        </>
      )}
      <div className="card warn">{warrantyNote.text} <Cite c={warrantyNote.confidence} url={warrantyNote.source} /></div>
    </>
  );
}
