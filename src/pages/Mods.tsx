import { modStages, warrantyNote } from '../data/mods';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';


export default function Mods() {
  const t = useT();
  const used = modStages.filter((m) => m.status !== 'excluded');
  const excluded = modStages.filter((m) => m.status === 'excluded');
  return (
    <>
      <h1>{t('nav.mods')}</h1>
      <p className="lede">{t('mods.lede')}</p>
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
        <h2>{t('mods.excluded')}</h2>
        <ul className="rows">{excluded.map((m) => <li key={m.id}><s>{m.parts}</s> — {m.result} <Cite c={m.confidence} url={m.source} /></li>)}</ul>
      </section>
      <div className="card warn">{warrantyNote.text} <Cite c={warrantyNote.confidence} url={warrantyNote.source} /></div>
    </>
  );
}
