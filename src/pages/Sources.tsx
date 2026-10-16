import { allSourceUrls, REPORT_PATH } from '../data';
import { hostOf } from '../components/Facts';
import { factRows, toCsv, toJson } from '../lib/factExport';
import { today } from '../lib/garage';

function download(name: string, text: string, type: string) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function ExportFacts() {
  const n = factRows().length;
  return (
    <section className="card" id="export">
      <h2>Download the data</h2>
      <p className="muted">All {n} sourced facts, one row each (conflicting values, guide steps and other nested citations get their own rows), with source URL and confidence. CSV opens in a spreadsheet; JSON is for scripts.</p>
      <div className="btn-row">
        <button className="btn" onClick={() => download(`gt500-facts-${today()}.csv`, toCsv(factRows()), 'text/csv;charset=utf-8')}>Download CSV</button>
        <button className="btn ghost" onClick={() => download(`gt500-facts-${today()}.json`, toJson(factRows()), 'application/json')}>Download JSON</button>
      </div>
    </section>
  );
}

export default function Sources() {
  const urls = allSourceUrls();
  const byHost = urls.reduce<Record<string, string[]>>((acc, u) => { (acc[hostOf(u)] ||= []).push(u); return acc; }, {});
  return (
    <>
      <h1>Sources</h1>
      <p className="lede">Every URL cited in the app ({urls.length}). Content compiled from the project research report (<code>{REPORT_PATH}</code>) and notes. Inclusion is not endorsement; some pages are forums, listings or vendor claims — see each fact's confidence badge.</p>
      <ExportFacts />
      {Object.keys(byHost).sort().map((h) => (
        <section key={h} className="card">
          <h2 className="host">{h}</h2>
          <ul className="srclist">{byHost[h].map((u) => <li key={u}><a href={u} target="_blank" rel="noopener noreferrer">{u}</a></li>)}</ul>
        </section>
      ))}
    </>
  );
}
