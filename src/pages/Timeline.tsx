import { useMemo, useState } from 'react';
import { usdFixed } from '../lib/format';
import { Link } from 'react-router';
import { activeCarId, carLabel, forCar, loadCars, loadTrack } from '../lib/garage';
import { loadDrag } from '../lib/drag';
import { loadFuel } from '../lib/fuel';
import { KIND_LABEL, buildTimeline, filterTimeline, yearlySummary, type EventKind } from '../lib/timeline';
import { useT, useUnits } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';
import { fmtQty } from '../lib/units';

const KINDS = Object.keys(KIND_LABEL) as EventKind[];
const KL = (k: EventKind) => `tl.kind.${k}` as MsgKey;
const money = (n: number) => usdFixed(n);

export default function Timeline() {
  const u = useUnits();
  const t = useT();
  const [allCars, setAllCars] = useState(false);
  const store = useMemo(loadCars, []);
  const multi = store.cars.length > 1;
  const { all, fuel } = useMemo(() => {
    const ids = allCars ? store.cars.map((c) => c.id) : [activeCarId()];
    const track = loadTrack(), drag = loadDrag(), fuelAll = loadFuel();
    const fuel = ids.flatMap((id) => forCar(fuelAll, id));
    const all = ids.flatMap((id) => {
      const i = store.cars.findIndex((c) => c.id === id);
      const ev = buildTimeline(store.cars[i], forCar(track, id), forCar(drag, id), forCar(fuelAll, id));
      return multi && allCars ? ev.map((e) => ({ ...e, id: `${id}-${e.id}`, title: `${carLabel(store.cars[i], i)}: ${e.title}` })) : ev;
    }).sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
    return { all, fuel };
  }, [allCars, store, multi]);
  const [kinds, setKinds] = useState<EventKind[]>(KINDS);
  const [year, setYear] = useState('');
  const years = [...new Set(all.map((e) => e.date.slice(0, 4)))].sort().reverse();
  const shown = filterTimeline(all, kinds, year || null);
  const summary = yearlySummary(all, fuel);
  const toggle = (k: EventKind) => setKinds((ks) => (ks.includes(k) ? ks.filter((x) => x !== k) : [...ks, k]));

  return (
    <>
      <h1>{t('nav.timeline')}</h1>
      <p className="lede">{t('tl.lede')} <Link to="/garage">{t('nav.garage')}</Link> · <Link to="/track">{t('nav.track')}</Link> · <Link to="/drag">{t('nav.drag')}</Link> · <Link to="/fuel">{t('nav.fuel')}</Link></p>
      {multi && <label className="check"><input type="checkbox" checked={allCars} onChange={(e) => setAllCars(e.target.checked)} /><span>{t('tl.allCars')}</span></label>}
      {all.length === 0 ? <p className="muted">{t('tl.empty')}</p> : (
        <>
          <section className="card">
            <h2>{t('tl.yearly')}</h2>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('tl.yearlyTable')}>
              <table className="tbl">
                <thead><tr><th scope="col">{t('tl.year')}</th>{KINDS.map((k) => <th scope="col" key={k}>{t(KL(k))}</th>)}<th scope="col">{t('tl.fuelUsed')}</th><th scope="col">{t('tl.spend')}</th></tr></thead>
                <tbody>{summary.map((y) => (
                  <tr key={y.year}><th scope="row">{y.year}</th>{KINDS.map((k) => <td key={k}>{y.counts[k]}</td>)}<td>{y.gallons ? fmtQty('volume', y.gallons, u, 1) : '—'}</td>
                    <td>{money(y.spend)}{y.spend > 0 && <div className="small muted">{t('tl.split', { svc: money(y.serviceSpend), mods: money(y.modSpend), fuel: money(y.fuelSpend) })}</div>}</td></tr>
                ))}</tbody>
              </table>
            </div>
            <p className="muted small">{t('tl.spendNote')}</p>
          </section>
          <section className="card">
            <h2>{t('tl.filter')}</h2>
            <fieldset className="chips-field">
              <legend className="sr-only">{t('tl.types')}</legend>
              {KINDS.map((k) => (
                <label key={k} className="check inline"><input type="checkbox" checked={kinds.includes(k)} onChange={() => toggle(k)} /><span>{t(KL(k))}</span></label>
              ))}
            </fieldset>
            <label className="form-label">{t('tl.year')}
              <select className="input" value={year} onChange={(e) => setYear(e.target.value)}>
                <option value="">{t('market.allYears')}</option>
                {years.map((y) => <option key={y} value={y}>{y}</option>)}
              </select>
            </label>
            <p className="muted" role="status">{t('tl.count', { n: shown.length, all: all.length })}</p>
          </section>
          <ol className="timeline">
            {shown.map((e) => (
              <li key={e.id} className={`tl tl-${e.kind}`}>
                <div className="tl-date mono">{e.date}</div>
                <div className="tl-body"><span className={`tag tl-tag-${e.kind}`}>{t(KL(e.kind))}</span> <strong>{e.title}</strong>{e.cost !== null && <span className="muted"> · {money(e.cost)}</span>}
                  {e.detail && <div className="muted small wrap">{e.detail}</div>}</div>
              </li>
            ))}
          </ol>
        </>
      )}
    </>
  );
}
