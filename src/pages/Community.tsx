import { communities } from '../data/communities';
import { Cite } from '../components/Facts';

export default function Community() {
  return (
    <>
      <h1>Community</h1>
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
