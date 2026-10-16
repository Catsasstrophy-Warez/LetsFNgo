import { useState } from 'react';
import { Cite, Note, usd } from '../components/Facts';
import { YEARS, colorRows, headToHead, packageRows, priceGrid, rivals, yearCounts } from '../lib/yearDiff';
import { SHEET_CAVEAT } from '../data/competitors';

const KIND_LABEL = { msrp: 'Base MSRP', destination: 'Destination', 'gas-guzzler': 'Gas guzzler tax', delivered: 'Delivered / example', 'as-tested': 'As tested' } as const;

function Yes({ on, year }: { on: boolean; year: number }) {
  return on ? <span className="yes" aria-label={`Listed for ${year}`}>●</span> : <span className="no muted" aria-label={`Not listed for ${year}`}>–</span>;
}

export default function YearCompare() {
  const [onlyDiff, setOnlyDiff] = useState(true);
  const [rivalId, setRivalId] = useState(rivals()[0]?.id ?? '');
  const [hidden, setHidden] = useState(false);
  const cols = colorRows().filter((r) => !onlyDiff || r.differs);
  const pkgs = packageRows().filter((r) => !onlyDiff || r.differs);
  const h2h = headToHead(rivalId, hidden);
  return (
    <>
      <h1>Year &amp; Rival Compare</h1>
      <p className="lede">2020 vs 2021 vs 2022 generated from the sourced colors, packages and prices, plus a head-to-head with any rival using only sourced values. "Not listed" means no source places it in that year — not proof it was unavailable.</p>
      <div className="stats">
        {yearCounts().map((y) => <div className="stat" key={y.year}><div className="stat-v">{y.year}</div><div className="stat-l">{y.colors} colors · {y.packages} packages sourced</div></div>)}
      </div>
      <label className="check"><input type="checkbox" checked={onlyDiff} onChange={(e) => setOnlyDiff(e.target.checked)} /><span>Show only items that differ between years</span></label>
      <section className="card">
        <h2>Colors by year</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Colors by year table">
          <table className="tbl diff stack">
            <thead><tr><th scope="col">Color</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}<th scope="col">Ref.</th></tr></thead>
            <tbody>{cols.map(({ item: c, years }) => (
              <tr key={c.id}><th scope="row"><span className="dot" style={{ background: c.swatch }} aria-hidden /> {c.name}{c.code && <span className="muted small"> {c.code}</span>}{c.yearsNote && <div className="small muted">{c.yearsNote}</div>}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}><Yes on={years[y]} year={y} /></td>)}<td data-label="Ref."><Cite c={c.confidence} url={c.source} /></td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
      <section className="card">
        <h2>Packages by year</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Packages by year table">
          <table className="tbl diff stack">
            <thead><tr><th scope="col">Package</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}<th scope="col">Price</th><th scope="col">Ref.</th></tr></thead>
            <tbody>{pkgs.map(({ item: p, years }) => (
              <tr key={p.id}><th scope="row">{p.name}{p.note && <div className="small muted">{p.note}</div>}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}><Yes on={years[y]} year={y} /></td>)}<td data-label="Price">{usd(p.price.value)}</td><td data-label="Ref."><Cite c={p.confidence} url={p.source} /></td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
      <section className="card">
        <h2>Prices by year</h2>
        <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Prices by year table">
          <table className="tbl diff stack">
            <thead><tr><th scope="col">Item</th>{YEARS.map((y) => <th scope="col" key={y}>{y}</th>)}</tr></thead>
            <tbody>{priceGrid().map((r) => (
              <tr key={r.kind}><th scope="row">{KIND_LABEL[r.kind]}</th>
                {YEARS.map((y) => <td key={y} data-label={String(y)}>{r.cells[y].length ? r.cells[y].map((p) => <div key={p.id}><strong>{usd(p.value)}</strong> <span className="small muted">{p.label}</span> <Cite c={p.confidence} url={p.source} /></div>) : <span className="muted">Not sourced</span>}</td>)}</tr>
            ))}</tbody>
          </table>
        </div>
        <Note>Several cells hold conflicting figures from different sources; both are shown.</Note>
      </section>
      <section className="card">
        <h2>Head-to-head</h2>
        <label className="form-label">Rival
          <select className="input" value={rivalId} onChange={(e) => setRivalId(e.target.value)}>
            {rivals(true).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="check"><input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} /><span>Include hidden unverified spec rows</span></label>
        {h2h && (
          <>
            <div className="tbl-wrap" tabIndex={0} role="region" aria-label="Head-to-head table">
              <table className="tbl h2h">
                <thead><tr><th scope="col">Figure</th><th scope="col">GT500</th><th scope="col">{h2h.rival.name}</th></tr></thead>
                <tbody>{h2h.rows.filter((r) => r.gt500 !== null || r.rival !== null).map((r) => (
                  <tr key={r.label}><th scope="row">{r.label}</th>
                    <td className={r.better === 'gt500' ? 'win' : ''}>{r.gt500 ?? <span className="muted">Not sourced</span>}{r.better === 'gt500' && <span className="sr-only"> (better)</span>}</td>
                    <td className={r.better === 'rival' ? 'win' : ''}>{r.rival ?? <span className="muted">Not sourced</span>}{r.better === 'rival' && <span className="sr-only"> (better)</span>}</td></tr>
                ))}</tbody>
              </table>
            </div>
            <p className="small">Spec rows: GT500 {h2h.gtSheet ? <Cite c={h2h.gtSheet.confidence} url={h2h.gtSheet.source} /> : '—'} · {h2h.rival.name} {h2h.rivalSheet ? <Cite c={h2h.rivalSheet.confidence} url={h2h.rivalSheet.source} /> : <span className="muted">no spec sheet{h2h.rival.sheet?.hidden ? ' (hidden)' : ''}</span>}</p>
            <p className="small">Test rows (¼ mile test, lap, price): GT500 <Cite c={h2h.gt500.confidence} url={h2h.gt500.source} /> · {h2h.rival.name} <Cite c={h2h.rival.confidence} url={h2h.rival.source} /></p>
            <p>{h2h.rival.verdict}</p>
            <Note>{SHEET_CAVEAT} Highlighted cells are simply the larger/smaller number; figures come from different sources and methods.</Note>
          </>
        )}
      </section>
    </>
  );
}
