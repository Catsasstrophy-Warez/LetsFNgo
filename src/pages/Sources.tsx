import { allSourceUrls, REPORT_PATH } from '../data';
import { hostOf } from '../components/Facts';

export default function Sources() {
  const urls = allSourceUrls();
  const byHost = urls.reduce<Record<string, string[]>>((acc, u) => { (acc[hostOf(u)] ||= []).push(u); return acc; }, {});
  return (
    <>
      <h1>Sources</h1>
      <p className="lede">Every URL cited in the app ({urls.length}). Content compiled from the project research report (<code>{REPORT_PATH}</code>) and notes. Inclusion is not endorsement; some pages are forums, listings or vendor claims — see each fact's confidence badge.</p>
      {Object.keys(byHost).sort().map((h) => (
        <section key={h} className="card">
          <h2 className="host">{h}</h2>
          <ul className="srclist">{byHost[h].map((u) => <li key={u}><a href={u} target="_blank" rel="noopener noreferrer">{u}</a></li>)}</ul>
        </section>
      ))}
    </>
  );
}
