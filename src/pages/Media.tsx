import { useState } from 'react';
import { Badge } from '../components/Facts';
import { media, licensingNotes, photos, audio } from '../data/media';
import type { MediaItem } from '../data/types';
import { YouTube } from '../components/YouTube';
import { Cite } from '../components/Facts';
import { useT } from '../components/SettingsContext';


const CATS: MediaItem['category'][] = ['Official', 'Review', 'Comparison', 'Track', 'Onboard', 'Drag / Dyno', 'Stock sound', 'Aftermarket sound'];

export default function Media() {
  const t = useT();
  const [cat, setCat] = useState<MediaItem['category']>('Official');
  return (
    <>
      <h1>{t('nav.media')}</h1>
      <p className="lede">{t('media.lede')}</p>
      <div className="seg scroll">
        {CATS.map((c) => <button key={c} className={cat === c ? 'on' : ''} onClick={() => setCat(c)}>{t(`media.cat.${c}`)}</button>)}
      </div>
      <div className="media-grid">
        {media.filter((m) => m.category === cat).map((m) => (
          <article key={m.id} className="card">
            <YouTube id={m.youtubeId} title={m.title} />
            <h3>{m.title}</h3>
            <div className="credit">{t('media.video', { c: m.credit })} · <a href={m.source} target="_blank" rel="noopener noreferrer">{t('media.watch')}</a>{m.modified && <span className="tag tag-mod">{t('media.modified')}</span>}</div>
          </article>
        ))}
      </div>
      <h2>{t('media.photos')}</h2>
      <p className="muted">{t('media.photosNote')}</p>
      <div className="photo-grid">
        {photos.map((p) => (
          <figure key={p.id} className="card photo">
            <a href={p.source} target="_blank" rel="noopener noreferrer"><Thumb src={p.thumb} alt={p.title} /></a>
            <figcaption className="credit">
              {p.title}. {t('media.photo')} <a href={p.source} target="_blank" rel="noopener noreferrer">{p.author}</a>, <a href={p.licenseUrl} target="_blank" rel="noopener noreferrer">{p.license}</a>, {t('media.via')}
            </figcaption>
          </figure>
        ))}
      </div>
      <h2>{t('media.sounds')}</h2>
      <div className="card warn">{t('media.soundWarn')}</div>
      <div className="media-grid">
        {audio.map((a) => (
          <article key={a.id} className="card">
            <h3>{a.title} <Badge c={a.confidence} /></h3>
            <FreesoundEmbed id={a.freesoundId} title={a.title} />
            <div className="credit">“{a.title}” {t('media.by')} <a href={a.source} target="_blank" rel="noopener noreferrer">{a.author}</a>, <a href={a.licenseUrl} target="_blank" rel="noopener noreferrer">{a.license}</a>, {t('media.viaFs')} {a.note}</div>
          </article>
        ))}
      </div>
      <section className="card">
        <h2>{t('media.licensing')}</h2>
        <ul>{licensingNotes.map((n) => <li key={n.source}>{n.text} <Cite c={n.confidence} url={n.source} /></li>)}</ul>
      </section>
    </>
  );
}

function FreesoundEmbed({ id, title }: { id: string; title: string }) {
  const t = useT();
  const [on, setOn] = useState(false);
  if (!on) return <button className="btn" onClick={() => setOn(true)} aria-label={t('media.loadLabel', { t: title })}>{t('media.load')}</button>;
  return <iframe className="fs-embed" src={`https://freesound.org/embed/sound/iframe/${id}/simple/medium/`} title={title} loading="lazy" width="100%" height="130" />;
}

function Thumb({ src, alt }: { src: string; alt: string }) {
  const t = useT();
  const [failed, setFailed] = useState(false);
  if (failed) return <div className="thumb-fail">{t('media.imgFail')}</div>;
  return <img src={src} alt={alt} loading="lazy" decoding="async" referrerPolicy="no-referrer" onError={() => setFailed(true)} />;
}
