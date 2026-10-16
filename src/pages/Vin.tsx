import { useState } from 'react';
import { Link } from 'react-router-dom';
import { decodeVin } from '../lib/vin';
import { sampleVins, vinPositions, VPIC_URL } from '../data/vin';
import { NHTSA_LOOKUP } from '../data/recalls';
import { Cite, Note } from '../components/Facts';

export default function Vin() {
  const [vin, setVin] = useState('');
  const d = vin.trim() ? decodeVin(vin) : null;
  return (
    <>
      <h1>VIN Decoder</h1>
      <div className="card">
        <label htmlFor="vin">Enter a 17-character VIN</label>
        <input id="vin" className="input mono" value={vin} maxLength={24} autoCapitalize="characters" autoComplete="off" spellCheck={false}
          placeholder="1FA6P8SJ…" onChange={(e) => setVin(e.target.value)} />
        <div className="chips">Try: {sampleVins.map((v) => <button key={v} className="chip mono" onClick={() => setVin(v)}>{v}</button>)}</div>
      </div>
      {d && (
        <div className="card">
          <div className={`verdict ${d.valid && d.isGT500 ? 'ok' : d.valid ? 'warn' : 'bad'}`}>
            {!d.valid ? 'Invalid VIN' : d.isGT500 ? `Matches a ${d.year} Shelby GT500 pattern` : 'Valid VIN — not a 2020–22 GT500'}
          </div>
          {d.errors.map((e) => <p key={e} className="err">{e}</p>)}
          {d.warnings.map((w) => <p key={w} className="warn-t">{w}</p>)}
          {d.fields.length > 0 && (
            <table className="tbl"><thead><tr><th>Pos.</th><th>Value</th><th>Meaning</th></tr></thead>
              <tbody>{d.fields.map((f) => <tr key={f.position}><td>{f.position}</td><td className="mono">{f.value}</td><td>{f.meaning}</td></tr>)}</tbody>
            </table>
          )}
          <p className="muted">Pattern match only — confirm with <a href={VPIC_URL} target="_blank" rel="noopener noreferrer">NHTSA vPIC</a> and check open recalls at <a href={NHTSA_LOOKUP} target="_blank" rel="noopener noreferrer">nhtsa.gov/recalls</a>. Save it to your <Link to="/garage">Garage</Link>.</p>
        </div>
      )}
      <section className="card">
        <h2>How GT500 VINs read</h2>
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
