/** Owner-added pre-track checklist items, kept as a template on this device (and in backups from schema v8). */
import { load, save } from './storage';

export const PTC_KEY = 'gt500.ptc.v1';
export const MAX_USER_ITEMS = 20;
export const MAX_ITEM_LEN = 120;
export interface PtcTemplate { items: string[] }
export function normPtc(v: unknown): PtcTemplate | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const it = (v as { items?: unknown }).items;
  if (!Array.isArray(it) || !it.every((x) => typeof x === 'string')) return null;
  return { items: (it as string[]).map((x) => x.trim().slice(0, MAX_ITEM_LEN)).filter(Boolean).slice(0, MAX_USER_ITEMS) };
}
export const loadPtc = (): PtcTemplate => normPtc(load<unknown>(PTC_KEY, null)) ?? { items: [] };
export const savePtc = (p: PtcTemplate) => save(PTC_KEY, p);
