import { communities } from '../data/communities';
import { Cite } from '../components/Facts';
import { useT } from '../components/SettingsContext';


export default function Community() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.community')}</h1>
      {communities.map((c) => (
        <article key={c.id} className="card">
          <h3>{c.name}</h3>
          <p>{c.description}</p>
          <Cite c={c.confidence} url={c.source} />
        </article>
      ))}
    </>
  );
}
