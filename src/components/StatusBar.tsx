import { useEffect, useState } from 'react';
import { applyUpdate, onUpdateReady } from '../lib/sw';
import { onSaveError } from '../lib/storage';
import { useT } from './SettingsContext';

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
  return <StatusView online={online} update={update} saveErr={saveErr} setSaveErr={setSaveErr} />;
}

function StatusView({ online, update, saveErr, setSaveErr }: { online: boolean; update: boolean; saveErr: boolean; setSaveErr: (v: boolean) => void }) {
  const t = useT();
  return (
    <div className="statusbar" role="status" aria-live="polite">
      {!online && <p><span className="pill-off">{t('status.offline')}</span> {t('status.offlineText')}</p>}
      {update && <p><strong>{t('status.update')}</strong> <button className="btn small-btn" onClick={() => applyUpdate()}>{t('status.reload')}</button></p>}
      {saveErr && <p className="err">{t('status.saveErr')} <button className="link-btn" onClick={() => setSaveErr(false)}>{t('status.dismiss')}</button></p>}
    </div>
  );
}
