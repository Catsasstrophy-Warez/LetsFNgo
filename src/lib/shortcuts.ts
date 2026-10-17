/**
 * Desktop keyboard shortcuts: "/" search, "?" help, and two-key "g <x>" go-to sequences.
 * Keys typed into inputs, textareas, selects or contenteditable elements are ignored, as are
 * Ctrl/Meta/Alt chords, so shortcuts never steal typing or browser shortcuts.
 */
export const GO: Record<string, { to: string; key: string }> = {
  h: { to: '/', key: 'nav.home' },
  s: { to: '/specs', key: 'nav.specs' },
  g: { to: '/garage', key: 'nav.garage' },
  t: { to: '/timeline', key: 'nav.timeline' },
  r: { to: '/report', key: 'nav.report' },
  m: { to: '/market', key: 'nav.market' },
  a: { to: '/achievements', key: 'nav.achievements' },
  p: { to: '/settings', key: 'nav.settings' },
};
/** How long the second key of a "g" sequence is awaited. */
export const SEQ_MS = 1500;

export type ShortcutAction = { kind: 'search' } | { kind: 'help' } | { kind: 'go'; to: string } | { kind: 'close' };

export interface KeyLike { key: string; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean; target?: unknown }

/** True when the event comes from somewhere the user is typing. */
export function isTyping(target: unknown): boolean {
  if (!target || typeof target !== 'object') return false;
  const el = target as { tagName?: string; isContentEditable?: boolean; type?: string };
  if (el.isContentEditable) return true;
  const tag = (el.tagName ?? '').toUpperCase();
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag === 'INPUT') return !['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file'].includes((el.type ?? 'text').toLowerCase());
  return false;
}

/** Stateful matcher. Feed it keydown events; it returns the action to perform, or null. */
export function createShortcuts(now: () => number = () => Date.now()) {
  let pendingG: number | null = null;
  return (e: KeyLike): ShortcutAction | null => {
    if (e.key === 'Escape') { pendingG = null; return { kind: 'close' }; }
    if (e.ctrlKey || e.metaKey || e.altKey || isTyping(e.target)) { pendingG = null; return null; }
    const k = e.key;
    if (pendingG !== null && now() - pendingG <= SEQ_MS) {
      pendingG = null;
      const dest = GO[k.toLowerCase()];
      return dest ? { kind: 'go', to: dest.to } : null;
    }
    pendingG = null;
    if (k === '/') return { kind: 'search' };
    if (k === '?') return { kind: 'help' };
    if (k === 'g' || k === 'G') { pendingG = now(); return null; }
    return null;
  };
}
