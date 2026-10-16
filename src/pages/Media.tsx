import { useState } from 'react';
import { Badge } from '../components/Facts';
import { media, licensingNotes, photos, audio } from '../data/media';
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
      <h2>Photos (Wikimedia Commons)</h2>
      <p className="muted">Openly licensed photos shown from upload.wikimedia.org, not copied. Click a credit for the full file page and license.</p>
      <div className="photo-grid">
        {photos.map((p) => (
          <figure key={p.id} className="card photo">
            <a href={p.source} target="_blank" rel="noopener noreferrer"><Thumb src={p.thumb} alt={p.title} /></a>
            <figcaption className="credit">
              {p.title}. Photo: <a href={p.source} target="_blank" rel="noopener noreferrer">{p.author}</a>, <a href={p.licenseUrl} target="_blank" rel="noopener noreferrer">{p.license}</a>, via Wikimedia Commons.
            </figcaption>
          </figure>
        ))}
      </div>
      <h2>Sound clips (Freesound)</h2>
      <div className="card warn">These are generic Mustang / muscle-car recordings — <strong>not GT500 recordings</strong>. For the real car, see the “Stock sound” videos above.</div>
      <div className="media-grid">
        {audio.map((a) => (
          <article key={a.id} className="card">
            <h3>{a.title} <Badge c={a.confidence} /></h3>
            <FreesoundEmbed id={a.freesoundId} title={a.title} />
            <div className="credit">“{a.title}” by <a href={a.source} target="_blank" rel="noopener noreferrer">{a.author}</a>, <a href={a.licenseUrl} target="_blank" rel="noopener noreferrer">{a.license}</a>, via Freesound. {a.note}</div>
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

function FreesoundEmbed({ id, title }: { id: string; title: string }) {
  const [on, setOn] = useState(false);
  if (!on) return <button className="btn" onClick={() => setOn(true)} aria-label={`Load player: ${title}`}>▶ Load player (freesound.org)</button>;
  return <iframe className="fs-embed" src={`https://freesound.org/embed/sound/iframe/${id}/simple/medium/`} title={title} loading="lazy" width="100%" height="130" />;
}

function Thumb({ src, alt }: { src: string; alt: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <div className="thumb-fail">Image unavailable — view on Wikimedia Commons ↗</div>;
  return <img src={src} alt={alt} loading="lazy" decoding="async" referrerPolicy="no-referrer" onError={() => setFailed(true)} />;
}
