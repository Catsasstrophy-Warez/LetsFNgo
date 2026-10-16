import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { loadGarage, loadTrack } from '../lib/garage';
import { loadDrag } from '../lib/drag';
import { loadFuel } from '../lib/fuel';
import { KIND_LABEL, buildTimeline, filterTimeline, yearlySummary, type EventKind } from '../lib/timeline';
import { useUnits } from '../components/SettingsContext';
import { fmtQty } from '../lib/units';

const KINDS = Object.keys(KIND_LABEL) as EventKind[];
const money = (n: number) => `$${n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export default function Timeline() {
  const u = useUnits();
  const fuel = useMemo(loadFuel, []);
  const all = useMemo(() => buildTimeline(loadGarage(), loadTrack(), loadDrag(), fuel), [fuel]);
  const [kinds, setKinds] = useState<EventKind[]>(KINDS);
  const [year, setYear] = useState('');
  const years = [...new Set(all.map((e) => e.date.slice(0, 4)))].sort().reverse();
  const shown = filterTimeline(all, kinds, year || null);
  const summary = yearlySummary(all, fuel);
  const toggle = (k: EventKind) => setKinds((ks) => (ks.includes(k) ? ks.filter((x) => x !== k) : [...ks, k]));

  return (
    <>
      <h1>Ownership Timeline</h1>
      <p className="lede">Every dated entry from your <Link to="/garage">Garage</Link> service and mods logs, <Link to="/track">Track</Link>, <Link to="/drag">Drag</Link> and <Link to="/fuel">Fuel</Link> logs in one place.</p>
      {all.length === 0 ? <p className="muted">Nothing logged yet. Entries you add in the Garage and logs appear here.</p> : (
        <>
          <section className="card">
            <h2>Yearly summary</h2>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Yearly summary table">
              <table className="tbl">
                <thead><tr><th scope="col">Year</th>{KINDS.map((k) => <th scope="col" key={k}>{KIND_LABEL[k]}</th>)}<th scope="col">Fuel used</th><th scope="col">Logged spend</th></tr></thead>
                <tbody>{summary.map((y) => (
                  <tr key={y.year}><th scope="row">{y.year}</th>{KINDS.map((k) => <td key={k}>{y.counts[k]}</td>)}<td>{y.gallons ? fmtQty('volume', y.gallons, u, 1) : '—'}</td>
                    <td>{money(y.spend)}{y.spend > 0 && <div className="small muted">svc {money(y.serviceSpend)} · mods {money(y.modSpend)} · fuel {money(y.fuelSpend)}</div>}</td></tr>
                ))}</tbody>
              </table>
            </div>
            <p className="muted small">Spend counts only entries with a cost. Fuel cost is gallons × price per fill-up.</p>
          </section>
          <section className="card">
            <h2>Filter</h2>
            <fieldset className="chips-field">
              <legend className="sr-only">Entry types</legend>
              {KINDS.map((k) => (
                <label key={k} className="check inline"><input type="checkbox" checked={kinds.includes(k)} onChange={() => toggle(k)} /><span>{KIND_LABEL[k]}</span></label>
              ))}
            </fieldset>
            <label className="form-label">Year
              <select className="input" value={year} onChange={(e) => setYear(e.target.value)}>
                <option value="">All years</option>
                {years.map((y) => <option key={y} value={y}>{y}</option>)}
              </select>
            </label>
            <p className="muted" role="status">{shown.length} of {all.length} entries</p>
          </section>
          <ol className="timeline">
            {shown.map((e) => (
              <li key={e.id} className={`tl tl-${e.kind}`}>
                <div className="tl-date mono">{e.date}</div>
                <div className="tl-body"><span className={`tag tl-tag-${e.kind}`}>{KIND_LABEL[e.kind]}</span> <strong>{e.title}</strong>{e.cost !== null && <span className="muted"> · {money(e.cost)}</span>}
                  {e.detail && <div className="muted small wrap">{e.detail}</div>}</div>
              </li>
            ))}
          </ol>
        </>
      )}
    </>
  );
}
