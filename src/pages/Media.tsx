import { useState } from 'react';
import { media, licensingNotes } from '../data/media';
import type { MediaItem } from '../data/types';
import { YouTube } from '../components/YouTube';
import { Cite } from '../components/Facts';

const CATS: MediaItem['category'][] = ['Official', 'Review', 'Comparison', 'Track', 'Drag / Dyno', 'Stock sound', 'Aftermarket sound'];

export default function Media() {
  const [cat, setCat] = useState<MediaItem['category']>('Official');
  return (
    <>
      <h1>Media</h1>
      <p className="lede">Embedded from YouTube (privacy-enhanced mode). Videos load only when you tap play. All rights belong to the credited creators.</p>
      <div className="seg scroll">
        {CATS.map((c) => <button key={c} className={cat === c ? 'on' : ''} onClick={() => setCat(c)}>{c}</button>)}
      </div>
      <div className="media-grid">
        {media.filter((m) => m.category === cat).map((m) => (
          <article key={m.id} className="card">
            <YouTube id={m.youtubeId} title={m.title} />
            <h3>{m.title}</h3>
            <div className="credit">Video © {m.credit} · <a href={m.source} target="_blank" rel="noopener noreferrer">Watch on YouTube ↗</a>{m.modified && <span className="tag tag-mod">modified car</span>}</div>
          </article>
        ))}
      </div>
      <section className="card">
        <h2>Licensing notes</h2>
        <ul>{licensingNotes.map((n) => <li key={n.source}>{n.text} <Cite c={n.confidence} url={n.source} /></li>)}</ul>
      </section>
    </>
  );
}
