import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { decodeShare } from '../lib/share';
import { summarizePlan } from '../lib/planner';
import { KEYS, addCar, loadGarage, loadPlans, saveGarage, today, uid } from '../lib/garage';
import { useT } from '../components/SettingsContext';
import { useCar } from '../components/CarContext';
import { save } from '../lib/storage';
import { colors } from '../data/colors';

const money = (n: number) => `$${Math.round(n).toLocaleString('en-US')}`;

/** Read-only view of a shared plan or car summary (#/share/<payload>). Nothing is saved until "Import". */
export default function Share() {
  const { data = '' } = useParams();
  const r = decodeShare(data);
  const t = useT();
  const car = useCar();
  const nav = useNavigate();
  const [msg, setMsg] = useState('');
  if (!r.ok) return (<><h1>{t('sharev.link')}</h1><p className="err" role="alert">{r.error}</p><p><Link to="/">{t('sharev.home')}</Link></p></>);
  const d = r.data;

  if (d.k === 'plan') {
    const sum = summarizePlan(d.modIds);
    const importPlan = () => {
      const plans = loadPlans();
      if (save(KEYS.plans, [...plans, { id: uid(), name: `${d.name} (shared)`, modIds: d.modIds, created: today() }])) setMsg(t('sharev.planAdded'));
      else setMsg(t('common.saveFailed'));
    };
    return (
      <>
        <h1>{t('sharev.plan')}</h1>
        <p className="lede">{t('sharev.readOnly')}</p>
        <section className="card">
          <h2>{d.name}</h2>
          <p className="stat-v">{sum.pricedCount ? (sum.costMin === sum.costMax ? money(sum.costMin) : `${money(sum.costMin)}–${money(sum.costMax)}`) : '—'}<small>{t('sharev.sourcedPrices')}</small></p>
          {sum.unpricedCount > 0 && <p className="warn-t">{t('sharev.unpriced', { n: sum.unpricedCount })}</p>}
          <ul className="rows">{sum.mods.map((m) => <li key={m.id}><div className="sub">{m.stage}</div><p>{m.result}</p><Cite c={m.confidence} url={m.source} /></li>)}</ul>
          <button className="btn" onClick={importPlan}>{t('sharev.importPlan')}</button>
          {msg && <p className="ok-t" role="status">{msg} <Link to="/planner">{t('nav.planner')} →</Link></p>}
        </section>
        <Note>{t('sharev.gains')}</Note>
      </>
    );
  }

  const swatch = colors.find((c) => c.id === d.color);
  const sharedMods = () => d.mods.map((title) => ({ id: uid(), date: today(), title, notes: t('sharev.importedNote'), miles: '', cost: '' }));
  const addAsNew = () => {
    const id = addCar({ year: d.year, color: d.color, nickname: d.nickname, mods: sharedMods() });
    if (id) { car.switchCar(id); nav('/garage'); } else setMsg(t('sharev.addFailed'));
  };
  const importCar = () => {
    const g = loadGarage();
    if (!confirm(t('sharev.mergeConfirm'))) return;
    const ok = saveGarage({ ...g, year: g.year || d.year, color: g.color || d.color, nickname: g.nickname || d.nickname, mods: [...g.mods, ...sharedMods()] });
    car.refresh();
    setMsg(ok ? t('sharev.merged') : t('common.saveFailed'));
  };
  return (
    <>
      <h1>{t('sharev.car')}</h1>
      <p className="lede">{t('sharev.readOnly')} {t('sharev.noVin')}</p>
      <section className="card">
        <h2>{swatch && <span className="dot" style={{ background: swatch.swatch }} aria-hidden />} {d.nickname || 'GT500'}</h2>
        <p className="muted">{[d.year, swatch?.name].filter(Boolean).join(' · ') || t('sharev.notShared')}</p>
        <div className="sub">{t('sharev.mods', { n: d.mods.length })}</div>
        {d.mods.length ? <ul className="rows">{d.mods.map((m, i) => <li key={i}>{m}</li>)}</ul> : <p className="muted">{t('sharev.stock')}</p>}
        <div className="btn-row">
          <button className="btn" onClick={addAsNew}>{t('sharev.addNew')}</button>
          <button className="btn ghost" onClick={importCar}>{t('sharev.merge')}</button>
        </div>
        {msg && <p className="ok-t" role="status">{msg} <Link to="/garage">{t('nav.garage')} →</Link></p>}
      </section>
    </>
  );
}
