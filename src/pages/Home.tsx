import { Link } from 'react-router-dom';
import { CarArt } from '../components/CarArt';
import { Cite } from '../components/Facts';
import { specs } from '../data/specs';
import { colors } from '../data/colors';
import { NAV } from '../App';
import { loadGarage, loadPlans, loadTrack, nextDue, toNum, today } from '../lib/garage';

const pick = (id: string) => specs.find((s) => s.id === id)!;
const TOOLS = [
  { to: '/gearing', label: 'Gear & speed', d: 'mph per gear, rpm at speed' },
  { to: '/tools', label: 'Performance tools', d: '¼-mile estimate, power-to-weight' },
  { to: '/planner', label: 'Build planner', d: 'Sourced mods, cost range' },
  { to: '/track', label: 'Track day log', d: 'Laps, best, theoretical' },
];

function GarageSummary() {
  const g = loadGarage();
  const swatch = colors.find((c) => c.id === g.color);
  const due = nextDue(g.reminders, toNum(g.odometer), today());
  const empty = !g.nickname && !g.vin && !g.year && !g.color && !g.mods.length;
  return (
    <section className="card dash" aria-labelledby="dash-h">
      <div className="row-main"><h2 id="dash-h">My Garage</h2><Link to="/garage">Open →</Link></div>
      {empty ? <p className="muted">Add your car's year, color and VIN in the <Link to="/garage">Garage</Link> to see a summary here.</p> : (
        <p>
          {swatch && <span className="dot" style={{ background: swatch.swatch }} aria-hidden />}
          <strong>{g.nickname || 'My GT500'}</strong> <span className="muted">{[g.year, swatch?.name, g.odometer && `${g.odometer} mi`].filter(Boolean).join(' · ')}</span><br />
          <span className="muted">{g.mods.length} mod{g.mods.length === 1 ? '' : 's'} · {g.service.length} service entr{g.service.length === 1 ? 'y' : 'ies'} · {loadPlans().length} plan(s) · {loadTrack().length} track session(s)</span>
        </p>
      )}
      <div className="sub">Next maintenance</div>
      {due ? (
        <p><span className={`due due-${due.status.state}`}>{due.status.state === 'overdue' ? 'Overdue' : due.status.state === 'soon' ? 'Due soon' : 'Upcoming'}</span>{' '}
          {due.reminder.item}{due.status.dueMiles !== null && ` · ${due.status.dueMiles.toLocaleString('en-US')} mi`}{due.status.dueDate && ` · ${due.status.dueDate}`}</p>
      ) : <p className="muted">No reminders scheduled — set a last-service date or mileage in <Link to="/garage#maintenance">Garage</Link>.</p>}
    </section>
  );
}

export default function Home() {
  const tiles = [
    { k: 'hp', v: '760', u: 'hp' },
    { k: 'tq', v: '625', u: 'lb-ft' },
    { k: 'redline', v: '7,500', u: 'rpm' },
    { k: 'trans', v: '7-spd', u: 'DCT' },
  ];
  return (
    <>
      <section className="hero">
        <CarArt />
        <h1>2020–2022 Mustang Shelby GT500</h1>
        <p className="lede">A sourced reference: one supercharged 5.2L drivetrain, three model years of paint, packages and VIN codes. Every figure shows its source and confidence.</p>
      </section>
      <GarageSummary />
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
      <h2>Tools</h2>
      <div className="grid-links tools">
        {TOOLS.map((t) => <Link key={t.to} to={t.to} className="card link-card">{t.label} →<span className="muted small">{t.d}</span></Link>)}
      </div>
      <div className="legend card">
        <strong>Confidence:</strong> <span className="badge badge-confirmed">confirmed</span> primary or multiple sources ·{' '}
        <span className="badge badge-reported">reported</span> single secondary source ·{' '}
        <span className="badge badge-unverified">unverified</span> claim, inference or unknown
      </div>
      <h2>Reference</h2>
      <div className="grid-links">
        {NAV.filter((n) => n.to !== '/' && !TOOLS.some((t) => t.to === n.to)).map((n) => <Link key={n.to} to={n.to} className="card link-card">{n.label} →</Link>)}
      </div>
    </>
  );
}
