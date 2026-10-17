import { useCallback, useEffect, useRef, useState } from 'react';
import { useT } from './SettingsContext';
import type { MsgKey } from '../lib/i18n';
import { MAX_PER_OWNER, PhotoError, addPhoto, deletePhoto, onPhotosChanged, photosFor, type PhotoOwner, type PhotoRec } from '../lib/photos';

const ERR: Record<string, MsgKey> = {
  unsupported: 'ph.errUnsupported', notImage: 'ph.errNotImage', decode: 'ph.errDecode', tooBig: 'ph.errTooBig',
  perEntry: 'ph.errPerEntry', count: 'ph.errCount', quota: 'ph.errQuota', storage: 'ph.errStorage',
};

/** Object URLs for a list of blobs, revoked when the list changes or the component unmounts. */
function useUrls(blobs: Blob[]): string[] {
  const [urls, setUrls] = useState<string[]>([]);
  useEffect(() => {
    if (typeof URL === 'undefined' || !URL.createObjectURL) return;
    const u = blobs.map((b) => URL.createObjectURL(b));
    setUrls(u);
    return () => u.forEach((x) => URL.revokeObjectURL(x));
  }, [blobs]);
  return urls;
}

/** Thumbnails, "Add photo" and a lightbox for one Garage entry or Track session. Photos stay on this device. */
export function PhotoAttach({ owner, label }: { owner: PhotoOwner; label: string }) {
  const t = useT();
  const [list, setList] = useState<PhotoRec[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [open, setOpen] = useState<number | null>(null);
  const reload = useCallback(() => { photosFor(owner).then(setList).catch(() => setList([])); }, [owner.kind, owner.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { reload(); return onPhotosChanged(reload); }, [reload]);
  const [thumbs, setThumbs] = useState<Blob[]>([]);
  useEffect(() => setThumbs(list.map((p) => p.thumb)), [list]);
  const urls = useUrls(thumbs);

  const add = async (files: FileList | null) => {
    if (!files?.length) return;
    setBusy(true); setErr('');
    try {
      for (const f of Array.from(files)) await addPhoto(owner, f);
    } catch (e) {
      setErr(t(ERR[e instanceof PhotoError ? e.code : 'storage'] ?? 'ph.errStorage', { n: MAX_PER_OWNER }));
    } finally { setBusy(false); }
  };

  return (
    <div className="photos">
      {list.length > 0 && (
        <ul className="photo-strip" aria-label={t('ph.listLabel', { x: label })}>
          {list.map((p, i) => (
            <li key={p.id}>
              <button type="button" className="photo-thumb" onClick={() => setOpen(i)} aria-label={t('ph.open', { n: i + 1, x: label })}>
                {urls[i] && <img src={urls[i]} alt="" width={72} height={72} />}
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="photo-row">
        {list.length < MAX_PER_OWNER && (
          <label className={`link-btn file-btn small${busy ? ' muted' : ''}`}>{busy ? t('ph.adding') : t('ph.add')}
            <input type="file" accept="image/*" multiple className="sr-only" disabled={busy} aria-label={t('ph.addLabel', { x: label })} onChange={(e) => { add(e.target.files); e.target.value = ''; }} />
          </label>
        )}
        {list.length > 0 && <span className="muted small">{t('ph.count', { n: list.length, max: MAX_PER_OWNER })}</span>}
      </div>
      {err && <p className="err small" role="alert">{err}</p>}
      {open !== null && list[open] && <Lightbox photos={list} index={open} label={label} onIndex={setOpen} onClose={() => setOpen(null)} />}
    </div>
  );
}

function Lightbox({ photos, index, label, onIndex, onClose }: { photos: PhotoRec[]; index: number; label: string; onIndex: (i: number) => void; onClose: () => void }) {
  const t = useT();
  const ref = useRef<HTMLDialogElement>(null);
  const p = photos[index];
  const [blob, setBlob] = useState<Blob[]>([p.blob]);
  useEffect(() => setBlob([p.blob]), [p.blob]);
  const [url] = useUrls(blob);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open && typeof d.showModal === 'function') d.showModal();
  }, []);
  const go = (k: number) => onIndex((index + k + photos.length) % photos.length);
  const del = async () => {
    if (!confirm(t('ph.confirmDelete'))) return;
    await deletePhoto(p.id).catch(() => undefined);
    if (photos.length <= 1) onClose(); else onIndex(Math.max(0, index - 1));
  };
  return (
    <dialog ref={ref} className="lightbox" aria-label={t('ph.viewer', { n: index + 1, total: photos.length, x: label })} onClose={onClose} onCancel={onClose}
      onKeyDown={(e) => { if (e.key === 'ArrowRight') go(1); else if (e.key === 'ArrowLeft') go(-1); }}>
      {url && <img src={url} alt={t('ph.alt', { n: index + 1, x: label, d: p.created.slice(0, 10) })} width={p.w} height={p.h} />}
      <p className="muted small">{t('ph.meta', { n: index + 1, total: photos.length, w: p.w, h: p.h, kb: Math.round(p.bytes / 1024), d: p.created.slice(0, 10) })}</p>
      <div className="btn-row">
        {photos.length > 1 && <><button type="button" className="btn ghost" onClick={() => go(-1)}>{t('ph.prev')}</button><button type="button" className="btn ghost" onClick={() => go(1)}>{t('ph.next')}</button></>}
        <button type="button" className="btn ghost danger-btn" onClick={del}>{t('common.delete')}</button>
        <button type="button" className="btn" onClick={() => { ref.current?.close(); onClose(); }} autoFocus>{t('ph.close')}</button>
      </div>
    </dialog>
  );
}
