import { plannable } from './planner';
import { colors } from '../data/colors';
import { tr } from './i18n';

/**
 * Shareable links: a build plan or car summary encoded as versioned, base64url JSON in the URL hash
 * (`#/share/<payload>`). No server is involved. Decoding is strict: size-capped, charset-checked,
 * every field allow-listed and length-limited; anything else is rejected.
 */
export const SHARE_VERSION = 1;
export const MAX_SHARE_CHARS = 2000;
const MAX_NAME = 60, MAX_MODS = 30, MAX_MOD_TITLE = 80;

export type SharePayload =
  | { v: 1; k: 'plan'; name: string; modIds: string[] }
  | { v: 1; k: 'car'; year: '' | '2020' | '2021' | '2022'; color: string; nickname: string; mods: string[] };

function b64urlEncode(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = '';
  bytes.forEach((b) => { bin += String.fromCharCode(b); });
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlDecode(s: string): string {
  const b = s.replace(/-/g, '+').replace(/_/g, '/');
  const bin = atob(b + '='.repeat((4 - (b.length % 4)) % 4));
  return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

// eslint-disable-next-line no-control-regex
const clean = (s: string, max: number) => s.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, max);

/** Encode, trimming oversized fields. Returns null if the result would still exceed the cap. */
export function encodeShare(p: SharePayload): string | null {
  const norm: SharePayload = p.k === 'plan'
    ? { v: 1, k: 'plan', name: clean(p.name, MAX_NAME), modIds: p.modIds.filter((id) => plannable.some((m) => m.id === id)).slice(0, MAX_MODS) }
    : { v: 1, k: 'car', year: p.year, color: p.color, nickname: clean(p.nickname, MAX_NAME), mods: p.mods.map((m) => clean(m, MAX_MOD_TITLE)).filter(Boolean).slice(0, MAX_MODS) };
  const out = b64urlEncode(JSON.stringify(norm));
  return out.length <= MAX_SHARE_CHARS ? out : null;
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === 'object' && !Array.isArray(v);
const strArr = (v: unknown, max: number, len: number) => Array.isArray(v) && v.length <= max && v.every((x) => typeof x === 'string' && x.length <= len);

export function decodeShare(raw: string): { ok: true; data: SharePayload } | { ok: false; error: string } {
  if (typeof raw !== 'string' || !raw) return { ok: false, error: tr('sharelink.e0') };
  if (raw.length > MAX_SHARE_CHARS) return { ok: false, error: tr('sharelink.e1') };
  if (!/^[A-Za-z0-9_-]+$/.test(raw)) return { ok: false, error: tr('sharelink.e2') };
  let v: unknown;
  try { v = JSON.parse(b64urlDecode(raw)); } catch { return { ok: false, error: tr('sharelink.e3') }; }
  if (!isObj(v)) return { ok: false, error: tr('sharelink.e4') };
  if (v.v !== SHARE_VERSION) return { ok: false, error: typeof v.v === 'number' && v.v > SHARE_VERSION ? tr('sharelink.e10') : tr('sharelink.e11') };
  if (v.k === 'plan') {
    if (typeof v.name !== 'string' || v.name.length > MAX_NAME || !strArr(v.modIds, MAX_MODS, 40)) return { ok: false, error: tr('sharelink.e5') };
    const ids = [...new Set(v.modIds as string[])];
    if (!ids.every((id) => plannable.some((m) => m.id === id))) return { ok: false, error: tr('sharelink.e6') };
    return { ok: true, data: { v: 1, k: 'plan', name: clean(v.name, MAX_NAME) || 'Shared plan', modIds: ids } };
  }
  if (v.k === 'car') {
    if (!['', '2020', '2021', '2022'].includes(v.year as string) || typeof v.color !== 'string' || typeof v.nickname !== 'string' || v.nickname.length > MAX_NAME || !strArr(v.mods, MAX_MODS, MAX_MOD_TITLE))
      return { ok: false, error: tr('sharelink.e7') };
    if (v.color && !colors.some((c) => c.id === v.color)) return { ok: false, error: tr('sharelink.e8') };
    return { ok: true, data: { v: 1, k: 'car', year: v.year as '', color: v.color, nickname: clean(v.nickname, MAX_NAME), mods: (v.mods as string[]).map((m) => clean(m, MAX_MOD_TITLE)).filter(Boolean) } };
  }
  return { ok: false, error: tr('sharelink.e9') };
}

/** Full link for the current deployment (works under any subpath; HashRouter). */
export function shareUrl(payload: string, loc: { origin: string; pathname: string } = location): string {
  return `${loc.origin}${loc.pathname}#/share/${payload}`;
}
