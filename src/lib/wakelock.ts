/**
 * Screen Wake Lock controller. Pure enough to unit test with a fake `request`.
 * Guards against overlapping requests: `acquire()` can be called from both the "timer started" effect and a
 * visibilitychange event before the first request resolves; previously both requests succeeded and one sentinel
 * was never released (the screen stayed on after the timer stopped).
 */
export type WakeState = 'unsupported' | 'off' | 'on' | 'failed';
export interface Sentinel { release: () => Promise<void>; addEventListener?: (t: 'release', f: () => void) => void }

export function createWakeLock(request: (() => Promise<Sentinel>) | null, onState: (s: WakeState) => void, isVisible: () => boolean = () => true) {
  let sentinel: Sentinel | null = null;
  let pending = false;
  let wanted = false;
  let disposed = false;
  const acquire = async () => {
    if (!request || disposed || !wanted || !isVisible() || sentinel || pending) return;
    pending = true;
    try {
      const s = await request();
      if (disposed || !wanted) { s.release().catch(() => undefined); return; }
      sentinel = s; onState('on');
      s.addEventListener?.('release', () => { if (sentinel === s) sentinel = null; if (!disposed) onState('off'); });
    } catch { if (!disposed) onState('failed'); } finally { pending = false; }
  };
  const release = () => { const s = sentinel; sentinel = null; s?.release().catch(() => undefined); };
  return {
    set(active: boolean) { wanted = active; if (active) return acquire(); release(); onState(request ? 'off' : 'unsupported'); return Promise.resolve(); },
    acquire,
    dispose() { disposed = true; wanted = false; release(); },
    get held() { return sentinel !== null; },
  };
}
