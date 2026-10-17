import { useState } from 'react';
import { Link } from 'react-router';
import { decodeVin } from '../lib/vin';
import { sampleVins, vinPositions, VPIC_URL } from '../data/vin';
import { NHTSA_LOOKUP } from '../data/recalls';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';


export default function Vin() {
  const t = useT();
  const [vin, setVin] = useState('');
  const d = vin.trim() ? decodeVin(vin) : null;
  return (
    <>
      <h1>{t('nav.vin')}</h1>
      <div className="card">
        <label htmlFor="vin">{t('vin.enter')}</label>
        <input id="vin" className="input mono" value={vin} maxLength={24} autoCapitalize="characters" autoComplete="off" spellCheck={false}
          placeholder="1FA6P8SJ…" onChange={(e) => setVin(e.target.value)} />
        <div className="chips">{t('vin.try')} {sampleVins.map((v) => <button key={v} className="chip mono" onClick={() => setVin(v)}>{v}</button>)}</div>
      </div>
      {d && (
        <div className="card">
          <div className={`verdict ${d.valid && d.isGT500 ? 'ok' : d.valid ? 'warn' : 'bad'}`}>
            {!d.valid ? t('vin.invalid') : d.isGT500 ? t('vin.match', { y: d.year ?? '' }) : t('vin.notGt500')}
          </div>
          {d.errors.map((e) => <p key={e} className="err">{e}</p>)}
          {d.warnings.map((w) => <p key={w} className="warn-t">{w}</p>)}
          {d.fields.length > 0 && (
            <table className="tbl"><thead><tr><th>{t('vin.pos')}</th><th>{t('vin.value')}</th><th>{t('vin.meaning')}</th></tr></thead>
              <tbody>{d.fields.map((f) => <tr key={f.position}><td>{f.position}</td><td className="mono">{f.value}</td><td>{f.meaning}</td></tr>)}</tbody>
            </table>
          )}
          <p className="muted">{t('vin.confirm')} <a href={VPIC_URL} target="_blank" rel="noopener noreferrer">NHTSA vPIC</a> {t('vin.recalls')} <a href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">nhtsa.gov/recalls</a>. {t('vin.save')} <Link to="/garage">{t('nav.garage')}</Link>.</p>
        </div>
      )}
      <section className="card">
        <h2>{t('vin.how')}</h2>
        <p className="mono">1FA6P8SJ?[L/M/N]5xxxxxx</p>
        <dl className="facts">
          {vinPositions.map((p) => (
            <div key={p.positions} className="fact"><dt>{p.positions}</dt><dd>{p.meaning} <Cite c={p.confidence} url={p.source} />{p.note && <Note>{p.note}</Note>}</dd></div>
          ))}
        </dl>
      </section>
    </>
  );
}
