/**
 * Photo attachments for Garage service/mod entries and Track sessions, kept in IndexedDB on this device only.
 *
 * Every photo is resized and re-encoded client-side (longest side ≤ MAX_DIM px, JPEG, quality stepped down until it
 * fits MAX_PHOTO_BYTES) with a small thumbnail, so originals with EXIF location never leave the browser. Per-entry,
 * total-count and total-size quotas are enforced before writing. Storage goes through a small backend interface, so
 * the quota rules are unit-tested with an in-memory backend; the app uses IndexedDB.
 */
import { MAX_DIM, MAX_PER_OWNER, MAX_PHOTOS, MAX_PHOTO_BYTES, MAX_TOTAL_BYTES, OWNER_ID_RE, PHOTO_KINDS, type PhotoBackup, type PhotoKind } from './photoLimits';
export * from './photoLimits';

export interface PhotoOwner { kind: PhotoKind; id: string }
export interface PhotoRec {
  id: string; kind: PhotoKind; ownerId: string; created: string;
  w: number; h: number; bytes: number;
  blob: Blob; thumb: Blob;
}

/** Longest side of a thumbnail (px). */
export const THUMB_DIM = 240;
/** Largest file accepted before resizing. */
export const MAX_INPUT_BYTES = 30 * 1024 * 1024;

export type PhotoErrorCode = 'unsupported' | 'notImage' | 'decode' | 'tooBig' | 'perEntry' | 'count' | 'quota' | 'storage';
export class PhotoError extends Error {
  constructor(public code: PhotoErrorCode) { super(code); }
}

/** Size that fits inside `max`×`max`, keeping the aspect ratio and never upscaling. */
export function fitWithin(w: number, h: number, max: number): { w: number; h: number } {
  if (!(w > 0 && h > 0)) return { w: 0, h: 0 };
  const k = Math.min(1, max / Math.max(w, h));
  return { w: Math.max(1, Math.round(w * k)), h: Math.max(1, Math.round(h * k)) };
}

export const newPhotoId = () => `p${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;

/* ---------- storage backends ---------- */

export interface PhotoBackend {
  all(): Promise<PhotoRec[]>;
  put(r: PhotoRec): Promise<void>;
  del(id: string): Promise<void>;
  clear(): Promise<void>;
}

export function memoryBackend(): PhotoBackend {
  const m = new Map<string, PhotoRec>();
  return {
    all: async () => [...m.values()],
    put: async (r) => { m.set(r.id, r); },
    del: async (id) => { m.delete(id); },
    clear: async () => { m.clear(); },
  };
}

export const DB_NAME = 'gt500-photos';
const STORE = 'photos';
function req<T>(r: IDBRequest<T>): Promise<T> {
  return new Promise((ok, bad) => { r.onsuccess = () => ok(r.result); r.onerror = () => bad(r.error); });
}
let dbp: Promise<IDBDatabase> | null = null;
function db(): Promise<IDBDatabase> {
  if (typeof indexedDB === 'undefined') return Promise.reject(new PhotoError('unsupported'));
  if (!dbp) {
    dbp = new Promise<IDBDatabase>((ok, bad) => {
      let r: IDBOpenDBRequest;
      try { r = indexedDB.open(DB_NAME, 1); } catch { bad(new PhotoError('unsupported')); return; }
      r.onupgradeneeded = () => { r.result.createObjectStore(STORE, { keyPath: 'id' }); };
      r.onsuccess = () => ok(r.result);
      r.onerror = () => bad(new PhotoError('unsupported'));
      r.onblocked = () => bad(new PhotoError('storage'));
    });
    dbp.catch(() => { dbp = null; });
  }
  return dbp;
}
async function tx<T>(mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const d = await db();
  const t = d.transaction(STORE, mode);
  const out = await req(f(t.objectStore(STORE)));
  await new Promise<void>((ok, bad) => { t.oncomplete = () => ok(); t.onerror = () => bad(t.error); t.onabort = () => bad(t.error); if (mode === 'readonly') ok(); });
  return out;
}
export function idbBackend(): PhotoBackend {
  const wrap = async <T>(p: () => Promise<T>): Promise<T> => {
    try { return await p(); } catch (e) {
      if (e instanceof PhotoError) throw e;
      throw new PhotoError(e instanceof DOMException && e.name === 'QuotaExceededError' ? 'quota' : 'storage');
    }
  };
  return {
    all: () => wrap(() => tx('readonly', (s) => s.getAll() as IDBRequest<PhotoRec[]>)),
    put: (r) => wrap(async () => { await tx('readwrite', (s) => s.put(r)); }),
    del: (id) => wrap(async () => { await tx('readwrite', (s) => s.delete(id)); }),
    clear: () => wrap(async () => { await tx('readwrite', (s) => s.clear()); }),
  };
}

let backend: PhotoBackend | null = null;
const be = () => (backend ??= idbBackend());
/** Swap the storage backend (tests use `memoryBackend()`). */
export const setPhotoBackend = (b: PhotoBackend | null) => { backend = b; };

/* ---------- change notification (thumbnails refresh after add/delete/import) ---------- */
type L = () => void;
const listeners = new Set<L>();
export function onPhotosChanged(f: L): () => void { listeners.add(f); return () => { listeners.delete(f); }; }
const changed = () => listeners.forEach((f) => f());

/* ---------- queries ---------- */

export const allPhotos = async (): Promise<PhotoRec[]> => (await be().all()).sort((a, b) => a.created.localeCompare(b.created) || a.id.localeCompare(b.id));
export const photosFor = async (o: PhotoOwner): Promise<PhotoRec[]> => (await allPhotos()).filter((p) => p.kind === o.kind && p.ownerId === o.id);
export async function usage(): Promise<{ count: number; bytes: number }> {
  const all = await be().all();
  return { count: all.length, bytes: all.reduce((a, p) => a + p.bytes, 0) };
}

/** Quota check for adding `bytes` more to `owner`. Throws a PhotoError naming the limit that would be exceeded. */
export function checkQuota(all: Pick<PhotoRec, 'kind' | 'ownerId' | 'bytes'>[], owner: PhotoOwner, bytes: number): void {
  if (bytes > MAX_PHOTO_BYTES + THUMB_BUDGET) throw new PhotoError('tooBig');
  if (all.filter((p) => p.kind === owner.kind && p.ownerId === owner.id).length >= MAX_PER_OWNER) throw new PhotoError('perEntry');
  if (all.length >= MAX_PHOTOS) throw new PhotoError('count');
  if (all.reduce((a, p) => a + p.bytes, 0) + bytes > MAX_TOTAL_BYTES) throw new PhotoError('quota');
}
/** Bytes allowed for a thumbnail on top of the photo. */
const THUMB_BUDGET = 100_000;

export interface Encoded { blob: Blob; thumb: Blob; w: number; h: number }
export type Encoder = (file: Blob) => Promise<Encoded>;

/** Resize + compress `file`, check quotas and store it for `owner`. */
export async function addPhoto(owner: PhotoOwner, file: Blob, encode: Encoder = encodeImage, now = new Date()): Promise<PhotoRec> {
  if (!OWNER_ID_RE.test(owner.id) || !PHOTO_KINDS.includes(owner.kind)) throw new PhotoError('storage');
  if (file.type && !file.type.startsWith('image/')) throw new PhotoError('notImage');
  if (file.size > MAX_INPUT_BYTES) throw new PhotoError('tooBig');
  // Cheap checks first, so a full entry fails before decoding a large image.
  const before = await be().all();
  checkQuota(before, owner, 0);
  const e = await encode(file);
  const bytes = e.blob.size + e.thumb.size;
  checkQuota(before, owner, bytes);
  const rec: PhotoRec = { id: newPhotoId(), kind: owner.kind, ownerId: owner.id, created: now.toISOString(), w: e.w, h: e.h, bytes, blob: e.blob, thumb: e.thumb };
  await be().put(rec);
  changed();
  return rec;
}

export async function deletePhoto(id: string): Promise<void> { await be().del(id); changed(); }
/** Remove every photo of an entry (when the entry itself is deleted). Never throws. */
export async function deletePhotosFor(o: PhotoOwner): Promise<void> {
  try { for (const p of await photosFor(o)) await be().del(p.id); changed(); } catch { /* storage unavailable: nothing to delete */ }
}
export async function clearPhotos(): Promise<void> { try { await be().clear(); changed(); } catch { /* unavailable */ } }

/* ---------- image encoding (browser) ---------- */

async function decode(file: Blob): Promise<{ src: CanvasImageSource; w: number; h: number; close: () => void }> {
  if (typeof createImageBitmap === 'function') {
    try {
      const b = await createImageBitmap(file, { imageOrientation: 'from-image' });
      return { src: b, w: b.width, h: b.height, close: () => b.close() };
    } catch { /* fall back to <img> */ }
  }
  if (typeof Image === 'undefined' || typeof URL === 'undefined') throw new PhotoError('decode');
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.decoding = 'async';
    img.src = url;
    await img.decode();
    return { src: img, w: img.naturalWidth, h: img.naturalHeight, close: () => undefined };
  } catch { throw new PhotoError('decode'); } finally { URL.revokeObjectURL(url); }
}

function toJpeg(src: CanvasImageSource, w: number, h: number, q: number): Promise<Blob> {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const ctx = c.getContext('2d');
  if (!ctx) return Promise.reject(new PhotoError('decode'));
  ctx.fillStyle = '#fff'; // transparent PNGs become white, not black, in JPEG
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(src, 0, 0, w, h);
  return new Promise((ok, bad) => c.toBlob((b) => (b ? ok(b) : bad(new PhotoError('decode'))), 'image/jpeg', q));
}

/** Decode, resize to ≤ MAX_DIM, encode JPEG under MAX_PHOTO_BYTES (lower quality, then smaller size) and make a thumbnail. */
export async function encodeImage(file: Blob): Promise<Encoded> {
  const img = await decode(file);
  try {
    if (!img.w || !img.h) throw new PhotoError('decode');
    let dim = MAX_DIM;
    for (let round = 0; round < 6; round++) {
      const s = fitWithin(img.w, img.h, dim);
      for (const q of [0.85, 0.75, 0.65, 0.55]) {
        const blob = await toJpeg(img.src, s.w, s.h, q);
        if (blob.size <= MAX_PHOTO_BYTES) {
          const ts = fitWithin(img.w, img.h, THUMB_DIM);
          const thumb = await toJpeg(img.src, ts.w, ts.h, 0.7);
          return { blob, thumb, w: s.w, h: s.h };
        }
      }
      dim = Math.round(dim * 0.8);
    }
    throw new PhotoError('tooBig');
  } finally { img.close(); }
}

/* ---------- backup (base64) ---------- */


export function bytesToB64(u8: Uint8Array): string {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
}
export function b64ToBytes(b64: string): Uint8Array {
  const s = atob(b64);
  const u8 = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
  return u8;
}

export async function photosToBackup(list?: PhotoRec[]): Promise<PhotoBackup[]> {
  const all = list ?? (await allPhotos());
  const out: PhotoBackup[] = [];
  for (const p of all) out.push({ id: p.id, kind: p.kind, ownerId: p.ownerId, created: p.created, w: p.w, h: p.h, data: bytesToB64(new Uint8Array(await p.blob.arrayBuffer())) });
  return out;
}

/**
 * Replace this device's photos with a backup's. Thumbnails are rebuilt with `encode` (falling back to the photo
 * itself). Returns how many were written.
 */
export async function restorePhotos(list: PhotoBackup[], encode: Encoder = encodeImage): Promise<number> {
  await be().clear();
  let n = 0;
  for (const p of list) {
    const bytes = b64ToBytes(p.data);
    const blob = new Blob([bytes as BlobPart], { type: 'image/jpeg' });
    let thumb: Blob = blob;
    try { thumb = (await encode(blob)).thumb; } catch { /* keep the full image as its own thumbnail */ }
    await be().put({ id: p.id, kind: p.kind, ownerId: p.ownerId, created: p.created, w: p.w, h: p.h, bytes: blob.size + (thumb === blob ? 0 : thumb.size), blob, thumb });
    n++;
  }
  changed();
  return n;
}
