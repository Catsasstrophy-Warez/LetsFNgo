import { Link } from 'react-router-dom';
import { CarArt } from '../components/CarArt';
import { Cite } from '../components/Facts';
import { specs } from '../data/specs';
import { NAV } from '../App';

const pick = (id: string) => specs.find((s) => s.id === id)!;

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
      <div className="legend card">
        <strong>Confidence:</strong> <span className="badge badge-confirmed">confirmed</span> primary or multiple sources ·{' '}
        <span className="badge badge-reported">reported</span> single secondary source ·{' '}
        <span className="badge badge-unverified">unverified</span> claim, inference or unknown
      </div>
      <div className="grid-links">
        {NAV.filter((n) => n.to !== '/').map((n) => <Link key={n.to} to={n.to} className="card link-card">{n.label} →</Link>)}
      </div>
    </>
  );
}
