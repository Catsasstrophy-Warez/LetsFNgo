import { maintenance } from '../data/maintenance';
import { recalls, NHTSA_LOOKUP } from '../data/recalls';
import { Cite, Conflicts, Note, fmt } from '../components/Facts';
import type { MaintenanceItem, RecallIssue } from '../data/types';
import { useT } from '../components/SettingsContext';


/** Mustang-wide NHTSA campaigns grouped by what the recall documents say about the GT500. */
export const APPLY_GROUPS: { key: NonNullable<RecallIssue['appliesToGT500']>; title: string; d: string }[] = [
  { key: 'yes', title: 'applies to the GT500', d: 'The recall documents name the GT500 (or its DCT). Still confirm your VIN.' },
  { key: 'likely', title: 'likely applies (VIN check)', d: 'No trim exclusion and the build window covers all 2020–22 GT500 production. Confirm by VIN.' },
  { key: 'vin', title: 'depends on VIN', d: 'The documents set no trim or engine limit; only cars in the build window or software state are affected. Check your VIN.' },
  { key: 'no', title: 'not applicable to the GT500', d: 'Limited to drivetrains the GT500 does not use.' },
];

const GROUPS: MaintenanceItem['group'][] = ['Fluids', 'Service', 'Warranty', 'Ownership'];

function Issue({ r }: { r: RecallIssue }) {
  const t = useT();
  return (
    <li>
      <div className="row-main"><span><span className="tag">{t(`own.kind.${r.kind}`)}</span> {r.title}</span>{r.years && <span className="muted">{r.years}</span>}</div>
      <p>{r.summary}</p>
      {r.buildWindow && <p className="small"><span className="muted">{t('own.build')}</span> {r.buildWindow}</p>}
      {r.evidence && <p className="small"><span className="muted">{t('own.evidence')}</span> {r.evidence}</p>}
      <div className="row-meta"><span className="muted">{t('own.campaign', { c: r.campaign ?? t('common.unknown') })}</span> <Cite c={r.confidence} url={r.source} /></div>
      {r.note && <Note>{r.note}</Note>}
    </li>
  );
}

export default function Ownership() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.ownership')}</h1>
      {GROUPS.map((g) => (
        <section key={g} className="card">
          <h2>{t(`own.group.${g}`)}</h2>
          <dl className="facts">
            {maintenance.filter((m) => m.group === g).map((m) => (
              <div key={m.id} className={`fact ${m.value === null ? 'unknown' : ''}`}><dt>{m.item}</dt><dd>
                <span className="val">{fmt(m.value, m.unit)}</span> <Cite c={m.confidence} url={m.source} />
                {m.conflicts && <><div className="conflict-tag">{t('common.sourcesDisagree')}</div><Conflicts values={m.conflicts} /></>}
                {m.warning && <p className="err">⚠ {m.warning}</p>}
                {m.note && <Note>{m.note}</Note>}
              </dd></div>
            ))}
          </dl>
        </section>
      ))}
      <section className="card">
        <h2>{t('own.recalls')}</h2>
        <a className="btn" href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">{t('own.check')}</a>
        <h3>{t('own.specific')}</h3>
        <ul className="rows">{recalls.filter((r) => r.kind !== 'nhtsa-recall').map((r) => <Issue key={r.id} r={r} />)}</ul>
      </section>
      {APPLY_GROUPS.map((g) => {
        const list = recalls.filter((r) => r.kind === 'nhtsa-recall' && r.appliesToGT500 === g.key);
        return list.length ? (
          <section className="card" key={g.key} id={`recalls-${g.key}`}>
            <h2>{t('own.nhtsa', { t: t(`own.apply.${g.key}.t`) })}</h2>
            <p className="muted">{t(`own.apply.${g.key}.d`)}</p>
            <ul className="rows">{list.map((r) => <Issue key={r.id} r={r} />)}</ul>
          </section>
        ) : null;
      })}
    </>
  );
}
