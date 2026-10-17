import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import { useSettings, useT } from '../components/SettingsContext';
import { useCar } from '../components/CarContext';
import { carLabel, loadCars, toNum, today } from '../lib/garage';
import { loadFuel } from '../lib/fuel';
import { buildReport, reportHtml, type VinMode } from '../lib/report';
import { fmtQty } from '../lib/units';
import { downloadText } from '../lib/download';
import type { LogEntry } from '../lib/garage';
import type { MsgKey } from '../lib/i18n';

/** Printable, owner-entered service history for resale. Print-to-PDF uses the browser; Download saves a standalone HTML file. */
export default function Report() {
  const t = useT();
  const { settings } = useSettings();
  const u = settings.units;
  const { active } = useCar();
  const store = useMemo(loadCars, []);
  const [carId, setCarId] = useState(active);
  const [vinMode, setVinMode] = useState<VinMode>('full');
  const car = store.cars.find((c) => c.id === carId) ?? store.cars[0];
  const m = useMemo(() => buildReport(car, loadFuel(), today(), vinMode), [car, vinMode]);
  const dist = (n: number | null) => (n === null ? '—' : fmtQty('distance', n, u));
  const slug = (m.title || 'gt500').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'gt500';
  const download = () => downloadText(reportHtml(m, t, u, settings.lang), `${slug}-service-history-${m.generated}.html`, 'text/html;charset=utf-8');

  const LogTable = ({ items, caption }: { items: LogEntry[]; caption: string }) => (
    <div className="tbl-wrap" tabIndex={0} role="region" aria-label={caption}>
      <table className="tbl">
        <caption className="sr-only">{caption}</caption>
        <thead><tr><th scope="col">{t('log.date')}</th><th scope="col">{t('report.work')}</th><th scope="col">{t('log.odometer')}</th><th scope="col">{t('log.cost')}</th></tr></thead>
        <tbody>{items.length ? items.map((x) => (
          <tr key={x.id}><td className="mono">{x.date}</td><td>{x.title}{x.notes && <div className="small muted wrap">{x.notes}</div>}</td><td>{dist(toNum(x.miles ?? ''))}</td><td>{x.cost ? `$${x.cost}` : '—'}</td></tr>
        )) : <tr><td colSpan={4} className="muted">{t('report.none')}</td></tr>}</tbody>
      </table>
    </div>
  );

  return (
    <article className="report">
      <h1>{t('report.docTitle', { car: m.title })}</h1>
      <div className="no-print card">
        <div className="form two">
          {store.cars.length > 1 && (
            <label>{t('report.car')}
              <select className="input" value={car.id} onChange={(e) => setCarId(e.target.value)}>
                {store.cars.map((c, i) => <option key={c.id} value={c.id}>{carLabel(c, i)}</option>)}
              </select>
            </label>
          )}
          <label>{t('report.vinMode')}
            <select className="input" value={vinMode} onChange={(e) => setVinMode(e.target.value as VinMode)}>
              <option value="full">{t('report.vinFull')}</option><option value="last6">{t('report.vinLast6')}</option><option value="none">{t('report.vinNone')}</option>
            </select>
          </label>
        </div>
        <div className="btn-row">
          <button className="btn" onClick={() => window.print()}>{t('report.print')}</button>
          <button className="btn ghost" onClick={download}>{t('report.download')}</button>
        </div>
        <p className="muted small">{t('report.howTo')} <Link to="/garage">{t('nav.garage')} →</Link></p>
      </div>
      <p className="muted">{t('report.generated', { d: m.generated })}</p>
      <p className="disclaimer" role="note">{t('report.disclaimer')}</p>
      <section className="card">
        <dl className="facts compact">
          <div className="fact"><dt>{t('garage.year')}</dt><dd>{m.year || '—'}</dd></div>
          <div className="fact"><dt>{t('garage.color')}</dt><dd>{m.colorName || '—'}</dd></div>
          <div className="fact"><dt>VIN</dt><dd className="mono">{m.vin || t('report.vinOmitted')}</dd></div>
          <div className="fact"><dt>{t('garage.odometer')}</dt><dd>{dist(m.odometer)}</dd></div>
          <div className="fact"><dt>{t('report.totals')}</dt><dd>{t('report.totalsText', { svc: `$${m.serviceSpend.toLocaleString('en-US')}`, mods: `$${m.modSpend.toLocaleString('en-US')}` })}</dd></div>
        </dl>
      </section>
      <section className="card"><h2>{t('garage.serviceLog')} ({m.service.length})</h2><LogTable items={m.service} caption={t('garage.serviceLog')} /></section>
      <section className="card"><h2>{t('garage.modsLog')} ({m.mods.length})</h2><LogTable items={m.mods} caption={t('garage.modsLog')} /></section>
      <section className="card">
        <h2>{t('report.odoTitle')}</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label={t('report.odoTitle')}>
          <table className="tbl">
            <thead><tr><th scope="col">{t('log.date')}</th><th scope="col">{t('log.odometer')}</th><th scope="col">{t('report.fromCol')}</th></tr></thead>
            <tbody>{m.odometerHistory.length ? m.odometerHistory.map((r, i) => <tr key={i}><td className="mono">{r.date}</td><td>{dist(r.miles)}</td><td>{t(`report.from.${r.from}` as MsgKey)}</td></tr>)
              : <tr><td colSpan={3} className="muted">{t('report.none')}</td></tr>}</tbody>
          </table>
        </div>
        {m.odometerWarnings.length > 0 && <p className="warn-t">{t('report.odoWarn')} {m.odometerWarnings.join('; ')}</p>}
      </section>
      <section className="card">
        <h2>{t('report.recallTitle')}</h2>
        <p>{t('report.recallText')} <a href={m.nhtsaUrl} target="_blank" rel="noopener noreferrer">nhtsa.gov/recalls ↗</a></p>
        <ul className="rows recall-check">
          {m.recalls.map((r) => (
            <li key={r.id}><span className="box" aria-hidden>☐</span> <strong>{r.campaign}</strong> — {r.title}
              <div className="small muted">{r.appliesToGT500 ? t(`report.applies.${r.appliesToGT500}` as MsgKey) : ''}{r.buildWindow ? ` · ${t('report.build')}: ${r.buildWindow}` : ''}</div></li>
          ))}
        </ul>
      </section>
      <p className="disclaimer">{t('report.disclaimer')}</p>
    </article>
  );
}
