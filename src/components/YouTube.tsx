import { useState } from 'react';

/** Click-to-load youtube-nocookie embed: nothing loads from YouTube until the user taps play. */
export function YouTube({ id, title }: { id: string; title: string }) {
  const [on, setOn] = useState(false);
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
