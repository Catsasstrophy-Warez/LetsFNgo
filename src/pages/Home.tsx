import { useState } from 'react';
import { Link } from 'react-router';
import { DASH_CARDS, loadDash, moveCard, saveDash, toggleCard } from '../lib/dashboard';
import { CarArt } from '../components/CarArt';
import { Cite } from '../components/Facts';
import { specs } from '../data/specs';
import { colors } from '../data/colors';
import { NAV } from '../App';
import { activeCarId, forCar, loadGarage, loadPlans, loadTrack, nextDue, toNum, today } from '../lib/garage';
import { useT } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';

const pick = (id: string) => specs.find((s) => s.id === id)!;
const TOOLS: { to: string; label: MsgKey; d: MsgKey }[] = [
  { to: '/gearing', label: 'nav.gearing', d: 'home.tool.gearing' },
  { to: '/tools', label: 'nav.tools', d: 'home.tool.tools' },
  { to: '/planner', label: 'nav.planner', d: 'home.tool.planner' },
  { to: '/track', label: 'nav.track', d: 'home.tool.track' },
  { to: '/drag', label: 'nav.drag', d: 'home.tool.drag' },
  { to: '/fuel', label: 'nav.fuel', d: 'home.tool.fuel' },
  { to: '/dyno', label: 'nav.dyno', d: 'home.tool.dyno' },
  { to: '/tires', label: 'nav.tires', d: 'home.tool.tires' },
  { to: '/timer', label: 'nav.timer', d: 'home.tool.timer' },
  { to: '/gps', label: 'nav.gps', d: 'home.tool.gps' },
  { to: '/timeline', label: 'nav.timeline', d: 'home.tool.timeline' },
  { to: '/report', label: 'nav.report', d: 'home.tool.report' },
  { to: '/market', label: 'nav.market', d: 'home.tool.market' },
  { to: '/achievements', label: 'nav.achievements', d: 'home.tool.achievements' },
  { to: '/diff', label: 'nav.diff', d: 'home.tool.diff' },
  { to: '/visualizer', label: 'nav.visualizer', d: 'home.tool.visualizer' },
  { to: '/quiz', label: 'nav.quiz', d: 'home.tool.quiz' },
];
const DASH_KEYS: Record<string, MsgKey> = { garage: 'home.card.garage', stats: 'home.card.stats', tools: 'home.card.tools', legend: 'home.card.legend', reference: 'home.card.reference' };

function GarageSummary() {
  const t = useT();
  const g = loadGarage();
  const sessions = forCar(loadTrack(), activeCarId()).length;
  const swatch = colors.find((c) => c.id === g.color);
  const due = nextDue(g.reminders, toNum(g.odometer), today());
  const empty = !g.nickname && !g.vin && !g.year && !g.color && !g.mods.length;
  return (
    <section className="card dash" aria-labelledby="dash-h">
      <div className="row-main"><h2 id="dash-h">{t('garage.title')}</h2><Link to="/garage">{t('common.open')} →</Link></div>
      {empty ? <p className="muted">{t('home.garageEmpty')} <Link to="/garage">{t('nav.garage')} →</Link></p> : (
        <p>
          {swatch && <span className="dot" style={{ background: swatch.swatch }} aria-hidden />}
          <strong>{g.nickname || t('home.myCar')}</strong> <span className="muted">{[g.year, swatch?.name, g.odometer && `${g.odometer} mi`].filter(Boolean).join(' · ')}</span><br />
          <span className="muted">{t('home.counts', { mods: g.mods.length, svc: g.service.length, plans: loadPlans().length, track: sessions })}</span>
        </p>
      )}
      <div className="sub">{t('home.nextMaint')}</div>
      {due ? (
        <p><span className={`due due-${due.status.state}`}>{t(due.status.state === 'overdue' ? 'due.overdue' : due.status.state === 'soon' ? 'due.soon' : 'due.upcoming')}</span>{' '}
          {due.reminder.item}{due.status.dueMiles !== null && ` · ${due.status.dueMiles.toLocaleString('en-US')} mi`}{due.status.dueDate && ` · ${due.status.dueDate}`}</p>
      ) : <p className="muted">{t('home.noReminders')} <Link to="/garage#maintenance">{t('nav.garage')} →</Link></p>}
    </section>
  );
}

export default function Home() {
  const t = useT();
  const [dash, setDashState] = useState(loadDash);
  const [edit, setEdit] = useState(false);
  const setDash = (d: typeof dash) => { setDashState(d); saveDash(d); };
  const tiles = [
    { k: 'hp', v: '760', u: 'hp' },
    { k: 'tq', v: '625', u: 'lb-ft' },
    { k: 'redline', v: '7,500', u: 'rpm' },
    { k: 'trans', v: '7-spd', u: 'DCT' },
  ];
  const cards: Record<string, JSX.Element> = {
    garage: <GarageSummary />,
    stats: (
      <div className="stats">
        {tiles.map((t) => {
          const s = pick(t.k);
          return (
            <div className="stat" key={t.k}>
              <div className="stat-v">{t.v}<small>{t.u}</small></div>
              <div className="stat-l">{s.label}</div>
              <Cite c={s.confidence} url={s.source} />
            </div>
          );
        })}
      </div>
    ),
    tools: (<><h2>{t('home.tools')}</h2><div className="grid-links tools">
      {TOOLS.map((x) => <Link key={x.to} to={x.to} className="card link-card">{t(x.label)} →<span className="muted small">{t(x.d)}</span></Link>)}
    </div></>),
    legend: (
      <div className="legend card">
        <strong>{t('home.confidence')}</strong> <span className="badge badge-confirmed">confirmed</span> {t('home.confirmed')} ·{' '}
        <span className="badge badge-reported">reported</span> {t('home.reported')} ·{' '}
        <span className="badge badge-unverified">unverified</span> {t('home.unverified')}
      </div>
    ),
    reference: (<><h2>{t('home.reference')}</h2><div className="grid-links">
      {NAV.filter((n) => n.to !== '/' && !TOOLS.some((x) => x.to === n.to)).map((n) => <Link key={n.to} to={n.to} className="card link-card">{t(n.key)} →</Link>)}
    </div></>),
  };
  const name = (id: string) => (DASH_KEYS[id] ? t(DASH_KEYS[id]) : DASH_CARDS.find((c) => c.id === id)?.label ?? id);
  return (
    <>
      <section className="hero">
        <CarArt />
        <h1>2020–2022 Mustang Shelby GT500</h1>
        <p className="lede">{t('home.lede')}</p>
      </section>
      {dash.order.filter((id) => !dash.hidden.includes(id)).map((id) => <div key={id} className="dash-slot">{cards[id]}</div>)}
      <div className="btn-row"><button className="btn ghost" aria-expanded={edit} aria-controls="dash-edit" onClick={() => setEdit((e) => !e)}>{edit ? t('home.doneCustom') : t('home.customize')}</button></div>
      {edit && (
        <section className="card" id="dash-edit" aria-labelledby="dash-edit-h">
          <h2 id="dash-edit-h">{t('home.customize')}</h2>
          <ol className="rows dash-edit">
            {dash.order.map((id, i) => (
              <li key={id} className="row-main">
                <label className="check"><input type="checkbox" checked={!dash.hidden.includes(id)} onChange={() => setDash(toggleCard(dash, id))} /><span>{name(id)}</span></label>
                <span className="btn-row tight">
                  <button className="btn ghost sm" disabled={i === 0} onClick={() => setDash(moveCard(dash, id, -1))} aria-label={t('home.moveUp', { x: name(id) })}>↑</button>
                  <button className="btn ghost sm" disabled={i === dash.order.length - 1} onClick={() => setDash(moveCard(dash, id, 1))} aria-label={t('home.moveDown', { x: name(id) })}>↓</button>
                </span>
              </li>
            ))}
          </ol>
          <button className="btn ghost" onClick={() => setDash({ order: DASH_CARDS.map((c) => c.id), hidden: [] })}>{t('home.resetLayout')}</button>
        </section>
      )}
    </>
  );
}
