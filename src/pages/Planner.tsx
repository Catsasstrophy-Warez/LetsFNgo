import { useEffect, useState } from 'react';
import { usdRange } from '../lib/format';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { save } from '../lib/storage';
import { KEYS, addModsToGarage, loadPlans, today, uid, type Plan } from '../lib/garage';
import { plannable, summarizePlan } from '../lib/planner';
import { checkPlan, orderOfOps } from '../lib/compat';
import { warrantyNote } from '../data/mods';
import { costPerHp } from '../lib/roi';
import { ShareLink } from '../components/ShareLink';
import { useT } from '../components/SettingsContext';


export default function Planner() {
  const t = useT();
  const [plans, setPlans] = useState<Plan[]>(loadPlans);
  const [activeId, setActiveId] = useState<string>(() => loadPlans()[0]?.id ?? '');
  const [flash, setFlash] = useState('');
  useEffect(() => { save(KEYS.plans, plans); }, [plans]);
  const active = plans.find((p) => p.id === activeId) ?? null;
  const sum = summarizePlan(active?.modIds ?? []);
  const warnings = checkPlan(sum.mods);
  const ordered = orderOfOps(sum.mods);

  const newPlan = () => {
    const p: Plan = { id: uid(), name: t('plan.default', { n: plans.length + 1 }), modIds: [], created: today() };
    setPlans([...plans, p]); setActiveId(p.id);
  };
  const update = (patch: Partial<Plan>) => setPlans((ps) => ps.map((p) => (p.id === activeId ? { ...p, ...patch } : p)));
  const toggle = (id: string) => active && update({ modIds: active.modIds.includes(id) ? active.modIds.filter((x) => x !== id) : [...active.modIds, id] });

  return (
    <>
      <h1>{t('nav.planner')}</h1>
      <p className="lede">{t('plan.lede')}</p>
      <section className="card">
        <div className="form">
          <label>{t('plan.plan')}
            <select className="input" value={activeId} onChange={(e) => setActiveId(e.target.value)}>
              {!plans.length && <option value="">{t('plan.none')}</option>}
              {plans.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </label>
          {active && <label>{t('plan.name')}<input className="input" value={active.name} onChange={(e) => update({ name: e.target.value })} /></label>}
        </div>
        <div className="btn-row">
          <button className="btn" onClick={newPlan}>{t('plan.new')}</button>
          {active && <button className="btn ghost" onClick={() => { if (confirm(t('plan.confirmDelete', { n: active.name }))) { const rest = plans.filter((p) => p.id !== active.id); setPlans(rest); setActiveId(rest[0]?.id ?? ''); } }}>{t('plan.delete')}</button>}
        </div>
      </section>
      {active && (
        <>
          <section className="card">
            <h2>{t('plan.choose')}</h2>
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
          {sum.mods.length > 0 && (
            <section className="card" aria-labelledby="compat-h">
              <h2 id="compat-h">{t('plan.compat')}</h2>
              {warnings.length === 0 ? <p className="muted">{t('plan.noCompat')}</p> : (
                <ul className="rows">
                  {warnings.map((w) => (
                    <li key={w.id} className={`compat compat-${w.severity}`}>
                      <p><strong>{w.severity === 'warn' ? '⚠ ' : 'ℹ '}{w.title}</strong></p>
                      <p>{w.text}</p>
                      <div className="row-meta">{w.basis.map((b) => <span key={b.label + b.source} className="small">{b.label} <Cite c={b.confidence} url={b.source} /></span>)}</div>
                    </li>
                  ))}
                </ul>
              )}
              <div className="sub">{t('plan.order')}</div>
              <ol className="rows">{ordered.map((m) => <li key={m.id}>{m.stage}</li>)}</ol>
              <Note>{t('plan.compatNote')}</Note>
            </section>
          )}
          <section className="card hl" aria-live="polite">
            <h2>{t('plan.count', { name: active.name, n: sum.mods.length })}</h2>
            <p className="stat-v">{sum.pricedCount ? usdRange(sum.costMin, sum.costMax) : '—'}<small>{t('sharev.sourcedPrices')}</small></p>
            {sum.unpricedCount > 0 && <p className="warn-t">{t('plan.unpriced', { n: sum.unpricedCount })}</p>}
            <ul className="rows">
              {sum.mods.map((m) => (
                <li key={m.id}>
                  <div className="sub">{m.stage}</div>
                  <p><strong>{m.result}</strong></p>
                  <div className="row-meta">{m.cost && <span className="tag">{usdRange(m.cost.min, m.cost.max)}</span>}<Cite c={m.confidence} url={m.source} /></div>
                  {m.note && <Note>{m.note}</Note>}
                </li>
              ))}
            </ul>
            <Note>{t('plan.gainsNote')}</Note>
            {sum.mods.length > 0 && (
              <button className="btn" onClick={() => { addModsToGarage(sum.mods.map((m) => ({ title: m.stage.replace(/^[\d·\s]+/, '') + t('plan.planned'), notes: t('plan.fromPlan', { parts: m.parts, name: active.name, src: m.source }) }))); setFlash(t('plan.added', { n: sum.mods.length })); }}>{t('plan.addGarage')}</button>
            )}
            {flash && <p className="ok-t" role="status">{flash} <Link to="/garage">{t('nav.garage')} →</Link></p>}
            {sum.mods.length > 0 && <ShareLink label={t('plan.share')} payload={{ v: 1, k: 'plan', name: active.name, modIds: active.modIds }} />}
          </section>
          {sum.mods.length > 0 && <RoiView mods={sum.mods} />}
        </>
      )}
      <div className="card warn">{warrantyNote.text} <Cite c={warrantyNote.confidence} url={warrantyNote.source} /></div>
    </>
  );
}

function RoiView({ mods }: { mods: ReturnType<typeof summarizePlan>['mods'] }) {
  const t = useT();
  const rows = costPerHp(mods);
  return (
    <section className="card" aria-labelledby="roi-h">
      <h2 id="roi-h">{t('plan.roi')}</h2>
      <ul className="rows">
        {rows.map((r) => (
          <li key={r.mod.id}>
            <div className="sub">{r.mod.stage}</div>
            {r.ok ? (
              <p><strong>{t('plan.perWhp', { v: usdRange(r.perHpMin, r.perHpMax) })}</strong> <span className="muted">· {t('plan.forCost', { g: r.gainWhp, c: usdRange(r.costMin, r.costMax) })}</span></p>
            ) : (
              <p className="muted"><span className="badge badge-unverified">{t('plan.insufficient')}</span> {t('plan.noSourced', { m: r.missing.map((x) => t(`plan.miss.${x}`)).join(t('plan.or')) })}</p>
            )}
            {r.mod.gain && <p className="small muted">{t('plan.gainBasis', { b: r.mod.gain.basis })} <Cite c={r.mod.confidence} url={r.mod.source} /></p>}
          </li>
        ))}
      </ul>
      <Note>{t('plan.roiNote')}</Note>
    </section>
  );
}
