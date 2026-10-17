/**
 * Guide checklists persist for the browser session only (sessionStorage), so ticks survive reloads and
 * navigation but start fresh next time. Not part of backups.
 */
export const checklistKey = (guideId: string) => `gt500.guide.${guideId}`;

type Store = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;
const ss = (): Store | null => { try { return typeof sessionStorage !== 'undefined' ? sessionStorage : null; } catch { return null; } };

export function loadChecks(guideId: string, steps: number, store: Store | null = ss()): boolean[] {
  const out = Array<boolean>(steps).fill(false);
  try {
    const v: unknown = JSON.parse(store?.getItem(checklistKey(guideId)) ?? 'null');
    if (Array.isArray(v)) v.slice(0, steps).forEach((x, i) => { out[i] = x === true; });
  } catch { /* corrupt → fresh */ }
  return out;
}

export function saveChecks(guideId: string, checks: boolean[], store: Store | null = ss()): void {
  try { store?.setItem(checklistKey(guideId), JSON.stringify(checks)); } catch { /* blocked storage: ticks just won't persist */ }
}
