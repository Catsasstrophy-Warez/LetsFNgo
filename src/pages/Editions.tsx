import { useState } from 'react';
import { Link } from 'react-router';
import { editions as ALL, editionGaps as GAPS } from '../data/editions';
import type { Confidence, ModelYear, ShelbyEdition } from '../data/types';
import { Cite, Conflicts, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { DEFAULT_EDITION_FILTER, filterEditions, type EditionFilter } from '../lib/catalog';
import { usdWhole } from '../lib/format';

/** Shelby American editions on the 2020–22 GT500: filters, sourced claims, and empty slots for what is unsourced. */
export default function Editions({ editions = ALL, gaps = GAPS }: { editions?: ShelbyEdition[]; gaps?: string[] }) {
  const t = useT();
  const [f, setF] = useState<EditionFilter>(DEFAULT_EDITION_FILTER);
  const shown = filterEditions(editions, f);
  const unknown = t('common.unknown');
  return (
    <>
      <h1>{t('nav.editions')}</h1>
      <p className="lede">{t('ed.lede')}</p>
      {editions.length === 0 ? (
        <section className="card" aria-labelledby="ed-empty">
          <h2 id="ed-empty">{t('ed.emptyTitle')}</h2>
          <p className="muted">{t('ed.empty')} <Link to="/years">{t('nav.years')} →</Link></p>
        </section>
      ) : (
        <>
          <section className="card" aria-labelledby="ed-f">
            <h2 id="ed-f">{t('market.filters')}</h2>
            <div className="form four">
              <label>{t('garage.year')}
                <select className="input" value={f.year ?? ''} onChange={(e) => setF({ ...f, year: e.target.value ? (Number(e.target.value) as ModelYear) : null })}>
                  <option value="">{t('market.allYears')}</option><option value="2020">2020</option><option value="2021">2021</option><option value="2022">2022</option>
                </select>
              </label>
              <label>{t('ed.confidence')}
                <select className="input" value={f.confidence ?? ''} onChange={(e) => setF({ ...f, confidence: (e.target.value || null) as Confidence | null })}>
                  <option value="">{t('market.any')}</option><option value="confirmed">confirmed</option><option value="reported">reported</option><option value="unverified">unverified</option>
                </select>
              </label>
            </div>
            <label className="check"><input type="checkbox" checked={f.streetLegalOnly} onChange={(e) => setF({ ...f, streetLegalOnly: e.target.checked })} /><span>{t('ed.streetOnly')}</span></label>
            <p className="muted" role="status">{t('ed.count', { shown: shown.length, all: editions.length })}</p>
          </section>
          {shown.length === 0 ? <p className="muted">{t('ed.noMatch')}</p> : shown.map((e) => (
            <section className="card" key={e.id} id={e.id} aria-labelledby={`${e.id}-h`}>
              <h2 id={`${e.id}-h`}>{e.name}</h2>
              <p className="small"><Cite c={e.confidence} url={e.source} /> <span className="muted">{t('ed.research', { l: e.research })}</span></p>
              <dl className="facts">
                <div className="fact"><dt>{t('ed.years')}</dt><dd>{e.years}</dd></div>
                <div className="fact"><dt>{t('ed.power')}</dt><dd>{e.hpClaim ?? unknown}</dd></div>
                <div className="fact"><dt>{t('ed.price')}</dt><dd>{e.price !== null ? usdWhole(e.price) : unknown}{e.priceNote && <span className="muted small"> ({e.priceNote})</span>}</dd></div>
                {e.upfitPrice !== undefined && <div className="fact"><dt>{t('ed.upfit')}</dt><dd>{e.upfitPrice !== null ? usdWhole(e.upfitPrice) : unknown}</dd></div>}
                <div className="fact"><dt>{t('ed.production')}</dt><dd>{e.production ?? unknown}</dd></div>
                <div className="fact"><dt>{t('ed.street')}</dt><dd>{e.streetLegal === null ? t('market.notStated') : e.streetLegal ? t('common.yes') : t('common.no')}</dd></div>
              </dl>
              {e.productionConflicts && <><div className="sub">{t('ed.conflict')}</div><Conflicts values={e.productionConflicts} /></>}
              <p><strong>{t('ed.content')}:</strong> {e.content ?? <span className="muted">{t('ed.contentNone')}</span>}</p>
              {e.note && <p className="small muted wrap">{e.note}</p>}
            </section>
          ))}
        </>
      )}
      {gaps.length > 0 && (
        <section className="card">
          <h2>{t('ed.gaps')}</h2>
          <p className="muted">{t('ed.gapsText')}</p>
          <ul>{gaps.map((g) => <li key={g}>{g}</li>)}</ul>
        </section>
      )}
      <Note>{t('ed.note')}</Note>
    </>
  );
}
