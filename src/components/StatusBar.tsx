import { useEffect, useState } from 'react';
import { applyUpdate, onUpdateReady } from '../lib/sw';
import { onSaveError } from '../lib/storage';

/** Offline notice, "update ready" prompt and storage-failure warning. */
export function StatusBar() {
  const [online, setOnline] = useState(() => (typeof navigator === 'undefined' ? true : navigator.onLine !== false));
  const [update, setUpdate] = useState(false);
  const [saveErr, setSaveErr] = useState(false);
  useEffect(() => {
    const on = () => setOnline(true), off = () => setOnline(false);
    window.addEventListener('online', on); window.addEventListener('offline', off);
    const u1 = onUpdateReady(setUpdate);
    const u2 = onSaveError(() => setSaveErr(true));
    return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off); u1(); u2(); };
  }, []);
  if (online && !update && !saveErr) return null;
  return (
    <div className="statusbar" role="status" aria-live="polite">
      {!online && <p><span className="pill-off">Offline</span> Saved pages and your data still work; videos and source links need a connection.</p>}
      {update && <p><strong>Update ready.</strong> <button className="btn small-btn" onClick={() => applyUpdate()}>Reload</button></p>}
      {saveErr && <p className="err">Could not save to this device (storage full or blocked). Export a backup from Settings. <button className="link-btn" onClick={() => setSaveErr(false)}>Dismiss</button></p>}
    </div>
  );
}
