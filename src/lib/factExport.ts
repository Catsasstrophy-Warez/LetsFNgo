import { collections } from '../data';
import type { Sourced } from '../data/types';

/** One sourced fact, flattened for researchers. Nested sourced values (conflicts, guide steps…) get their own row. */
export interface FactRow { collection: string; id: string; path: string; label: string; value: string; source: string; originalUrl: string; confidence: string; note: string }

type Obj = Record<string, unknown>;
const SKIP = new Set(['source', 'originalUrl', 'confidence', 'note', 'swatch', 'id']);
const NESTED = (v: unknown) => !!v && typeof v === 'object' && !Array.isArray(v) && ('source' in (v as Obj) || 'confidence' in (v as Obj));

/** A readable value: scalar fields (not label/id/source) joined as "key: value". Nested sourced records are rows of their own. */
function valueOf(o: Obj, labelKey: string | null): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(o)) {
    if (SKIP.has(k) || k === labelKey || NESTED(v)) continue;
    if (Array.isArray(v)) { if (v.some(NESTED)) continue; if (v.length) parts.push(`${k}: ${v.map((x) => (typeof x === 'object' ? JSON.stringify(x) : String(x))).join('; ')}`); }
    else if (v && typeof v === 'object') parts.push(`${k}: ${JSON.stringify(v)}`);
    else if (v !== undefined) parts.push(`${k}: ${v === null ? 'unknown' : String(v)}`);
  }
  return parts.join(' | ');
}
const LABELS = ['label', 'name', 'title', 'item', 'stage', 'number', 'positions', 'text'];

function walk(collection: string, rootId: string, path: string, o: Obj, out: FactRow[]) {
  if ('source' in o) {
    const labelKey = LABELS.find((k) => typeof o[k] === 'string') ?? null;
    const s = o as unknown as Sourced;
    out.push({ collection, id: rootId, path, label: labelKey ? String(o[labelKey]) : '', value: valueOf(o, labelKey), source: s.source, originalUrl: s.originalUrl ?? '', confidence: s.confidence ?? '', note: s.note ?? '' });
  }
  for (const [k, v] of Object.entries(o)) {
    if (Array.isArray(v)) v.forEach((x, i) => { if (x && typeof x === 'object') walk(collection, rootId, `${path}.${k}[${i}]`, x as Obj, out); });
    else if (NESTED(v)) walk(collection, rootId, `${path}.${k}`, v as Obj, out);
  }
}

/** Every sourced fact in the app, with source + confidence. */
export function factRows(cols: Record<string, Sourced[]> = collections): FactRow[] {
  const out: FactRow[] = [];
  for (const [name, recs] of Object.entries(cols)) recs.forEach((r, i) => {
    const o = r as unknown as Obj;
    const id = typeof o.id === 'string' ? o.id : `${name}-${i}`;
    walk(name, id, id, o, out);
  });
  return out;
}

const COLS: (keyof FactRow)[] = ['collection', 'id', 'path', 'label', 'value', 'source', 'originalUrl', 'confidence', 'note'];
/**
 * RFC 4180 quoting; cells starting with = + - @ (spreadsheet formulas), tab/CR/LF, or whitespace followed by a
 * formula character are prefixed with ' to stop CSV injection (some spreadsheets trim leading spaces).
 */
export function csvCell(s: string): string {
  const safe = /^[=+\-@\t\r\n]|^\s+[=+\-@]/.test(s) ? `'${s}` : s;
  return /[",\r\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}
export const toCsv = (rows: FactRow[]) => [COLS.join(','), ...rows.map((r) => COLS.map((c) => csvCell(r[c])).join(','))].join('\r\n') + '\r\n';
export const toJson = (rows: FactRow[], exported = new Date().toISOString()) =>
  JSON.stringify({ app: 'gt500-companion', kind: 'sourced-facts', exported, count: rows.length, facts: rows }, null, 2);
