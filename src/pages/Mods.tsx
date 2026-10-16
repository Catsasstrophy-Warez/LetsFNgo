import { modStages, warrantyNote } from '../data/mods';
import { Cite, Note } from '../components/Facts';

export default function Mods() {
  const used = modStages.filter((m) => m.status !== 'excluded');
  const excluded = modStages.filter((m) => m.status === 'excluded');
  return (
    <>
      <h1>Mods &amp; Tuning</h1>
      <p className="lede">The usual ladder: tune → pulley, fuel and E85 → larger blower → DCT limits. Stock is 760 hp / 625 lb-ft.</p>
      <ol className="ladder">
        {used.map((m) => (
          <li key={m.id} className="card">
            <div className="sub">{m.stage}</div>
            <h3>{m.result}</h3>
            <p>{m.parts}</p>
            <Cite c={m.confidence} url={m.source} />
            {m.note && <Note>{m.note}</Note>}
          </li>
        ))}
      </ol>
      <section className="card">
        <h2>Excluded / unverified claims</h2>
        <ul className="rows">{excluded.map((m) => <li key={m.id}><s>{m.parts}</s> — {m.result} <Cite c={m.confidence} url={m.source} /></li>)}</ul>
      </section>
      <div className="card warn">{warrantyNote.text} <Cite c={warrantyNote.confidence} url={warrantyNote.source} /></div>
    </>
  );
}
