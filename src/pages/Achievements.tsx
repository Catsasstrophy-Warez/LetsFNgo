import { useEffect, useMemo } from 'react';
import { Link } from 'react-router';
import { useT } from '../components/SettingsContext';
import { loadCars, loadPlans, loadTrack } from '../lib/garage';
import { loadDrag } from '../lib/drag';
import { loadFuel } from '../lib/fuel';
import { loadDyno } from '../lib/dyno';
import { computeAchievements, loadAch, saveAch, unseen } from '../lib/achievements';

/** Milestones derived from everything logged on this device (all cars). Nothing leaves the device. */
export default function Achievements() {
  const t = useT();
  const list = useMemo(() => computeAchievements({ cars: loadCars(), track: loadTrack(), drag: loadDrag(), fuel: loadFuel(), dyno: loadDyno(), plans: loadPlans().length }), []);
  const fresh = useMemo(() => unseen(list, loadAch()), [list]);
  useEffect(() => { if (fresh.length) { const st = loadAch(); saveAch({ seen: [...new Set([...st.seen, ...fresh])] }); } }, [fresh]);
  const done = list.filter((a) => a.done).length;
  return (
    <>
      <h1>{t('ach.title')}</h1>
      <p className="lede">{t('ach.lede')}</p>
      <p role="status"><strong>{t('ach.progress', { done, all: list.length })}</strong>{fresh.length > 0 && <> · <span className="ok-t">{t('ach.new', { n: fresh.length })}</span></>}</p>
      <ul className="ach-grid">
        {list.map((a) => (
          <li key={a.id} className={`card ach ${a.done ? 'ach-done' : ''}`}>
            <span className="ach-icon" aria-hidden>{a.icon}</span>
            <div>
              <h2 className="ach-t">{t(a.title)}{fresh.includes(a.id) && <span className="badge badge-confirmed ach-new">{t('ach.newBadge')}</span>}</h2>
              <p className="small muted">{t(a.desc)}</p>
              <progress max={a.target} value={a.current} aria-label={t('ach.bar', { name: t(a.title), cur: a.current, target: a.target })} />
              <p className="small">{a.done ? (a.date ? t('ach.doneOn', { d: a.date }) : t('ach.done')) : t('ach.left', { cur: a.current.toLocaleString('en-US'), target: a.target.toLocaleString('en-US') })}</p>
            </div>
          </li>
        ))}
      </ul>
      <p className="note">{t('ach.note')} <Link to="/garage">{t('nav.garage')} →</Link></p>
    </>
  );
}
