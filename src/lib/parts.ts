import { partNumbers } from '../data/parts';
import type { PartNumber } from '../data/types';

const norm = (s: string) => s.toLowerCase().replace(/[\s-]/g, '');

/** Search part numbers by number (dash/space-insensitive: "fl2087" finds FL-2087), brand, description or category. */
export function filterParts(q: string, list: PartNumber[] = partNumbers): PartNumber[] {
  const terms = q.toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return list;
  return list.filter((p) => {
    const hay = `${p.number} ${p.brand} ${p.description} ${p.category} ${p.kind === 'avoid' ? 'avoid wrong not' : ''}`.toLowerCase();
    const compact = norm(hay);
    return terms.every((t) => hay.includes(t) || compact.includes(norm(t)));
  });
}

/** Copy text: async Clipboard API first, then a hidden-textarea fallback (older WebViews, http). */
export async function copyText(text: string, nav: Pick<Navigator, 'clipboard'> | undefined = typeof navigator !== 'undefined' ? navigator : undefined): Promise<boolean> {
  try { if (nav?.clipboard?.writeText) { await nav.clipboard.writeText(text); return true; } } catch { /* fall through */ }
  if (typeof document === 'undefined') return false;
  try {
    const ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    const ok = document.execCommand('copy');
    ta.remove();
    return ok;
  } catch { return false; }
}
