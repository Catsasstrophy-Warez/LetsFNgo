import { useState } from 'react';
import { encodeShare, shareUrl, type SharePayload } from '../lib/share';

/** Builds a #/share link and offers native share / copy; always shows the URL so it can be copied by hand. */
export function ShareLink({ payload, label }: { payload: SharePayload; label: string }) {
  const [url, setUrl] = useState('');
  const [msg, setMsg] = useState('');
  const make = async () => {
    const enc = encodeShare(payload);
    if (!enc) { setMsg('Too much to fit in a link — remove some mods and try again.'); return; }
    const link = shareUrl(enc);
    setUrl(link);
    try {
      if (navigator.share) { await navigator.share({ title: 'GT500 Companion', url: link }); setMsg('Shared.'); return; }
      await navigator.clipboard.writeText(link);
      setMsg('Link copied.');
    } catch { setMsg('Copy the link below.'); }
  };
  return (
    <div className="share-link">
      <button className="btn ghost" type="button" onClick={make}>{label}</button>
      {url && <input className="input mono small" readOnly value={url} aria-label="Share link" onFocus={(e) => e.target.select()} />}
      {msg && <p className="muted small" role="status">{msg}</p>}
    </div>
  );
}
