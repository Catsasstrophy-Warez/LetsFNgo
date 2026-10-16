import { useState } from 'react';
import { encodeShare, shareUrl, type SharePayload } from '../lib/share';
import { useT } from './SettingsContext';

/** Builds a #/share link and offers native share / copy; always shows the URL so it can be copied by hand. */
export function ShareLink({ payload, label }: { payload: SharePayload; label: string }) {
  const t = useT();
  const [url, setUrl] = useState('');
  const [msg, setMsg] = useState('');
  const make = async () => {
    const enc = encodeShare(payload);
    if (!enc) { setMsg(t('share.tooMuch')); return; }
    const link = shareUrl(enc);
    setUrl(link);
    try {
      if (navigator.share) { await navigator.share({ title: 'GT500 Companion', url: link }); setMsg(t('share.shared')); return; }
      await navigator.clipboard.writeText(link);
      setMsg(t('share.copied'));
    } catch { setMsg(t('share.copyBelow')); }
  };
  return (
    <div className="share-link">
      <button className="btn ghost" type="button" onClick={make}>{label}</button>
      {url && <input className="input mono small" readOnly value={url} aria-label={t('share.link')} onFocus={(e) => e.target.select()} />}
      {msg && <p className="muted small" role="status">{msg}</p>}
    </div>
  );
}
