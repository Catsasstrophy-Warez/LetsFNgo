import { useState } from 'react';

/** Click-to-load youtube-nocookie embed: nothing loads from YouTube until the user taps play. */
/** YouTube video ids are exactly 11 URL-safe characters. */
export const isYouTubeId = (id: string) => /^[\w-]{11}$/.test(id);

export function YouTube({ id, title }: { id: string; title: string }) {
  const [on, setOn] = useState(false);
  if (!isYouTubeId(id)) return <p className="err">Invalid video id.</p>;
  if (on) {
    return (
      <div className="yt">
        <iframe
          src={`https://www.youtube-nocookie.com/embed/${id}?autoplay=1`}
          title={title}
          loading="lazy"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
          referrerPolicy="strict-origin-when-cross-origin"
          allowFullScreen
          sandbox="allow-scripts allow-same-origin allow-presentation allow-popups"
        />
      </div>
    );
  }
  return (
    <button className="yt yt-placeholder" onClick={() => setOn(true)} aria-label={`Play video: ${title}`}>
      <span className="yt-play">▶</span>
      <span className="yt-hint">Loads from youtube-nocookie.com</span>
    </button>
  );
}
