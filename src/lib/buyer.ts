/**
 * Buyer's guide checklist ticks (which pre-purchase inspection items are done). Ids refer to items built from
 * sourced data in buyerGuide.ts; this module imports no data so the backup chunk stays small. In backups since schema 10.
 */
import { load, save } from './storage';

export const BUYER_KEY = 'gt500.buyer.v1';
export const MAX_BUYER_CHECKS = 300;
export interface BuyerState { checked: string[] }
const ID = /^[a-z0-9:._-]{1,80}$/i;

/** Normalize stored/imported state; null when it is not an object with a `checked` array. Bad ids are dropped. */
export function normBuyer(v: unknown): BuyerState | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const c = (v as Record<string, unknown>).checked;
  if (!Array.isArray(c)) return null;
  const ids = [...new Set(c.filter((x): x is string => typeof x === 'string' && ID.test(x)))].slice(0, MAX_BUYER_CHECKS);
  return { checked: ids };
}
export const loadBuyer = (): BuyerState => normBuyer(load<unknown>(BUYER_KEY, null)) ?? { checked: [] };
export const saveBuyer = (s: BuyerState) => save(BUYER_KEY, normBuyer(s) ?? { checked: [] });
export const toggleCheck = (s: BuyerState, id: string, on: boolean): BuyerState =>
  ({ checked: on ? [...new Set([...s.checked, id])] : s.checked.filter((x) => x !== id) });
