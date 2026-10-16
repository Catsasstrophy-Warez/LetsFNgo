/**
 * Service-worker update flow. The new worker installs and WAITS; the page shows "Update ready";
 * tapping Reload posts SKIP_WAITING, and the page reloads once the new worker takes control.
 */
type Listener = (waiting: boolean) => void;
let waitingWorker: ServiceWorker | null = null;
const listeners = new Set<Listener>();

export function onUpdateReady(f: Listener): () => void { listeners.add(f); f(!!waitingWorker); return () => { listeners.delete(f); }; }
function setWaiting(w: ServiceWorker | null) { waitingWorker = w; listeners.forEach((f) => f(!!w)); }

/** Minimal shape of a registration, so the logic can be unit tested without a browser. */
export interface RegLike {
  waiting: ServiceWorker | null; installing: ServiceWorker | null;
  addEventListener(type: 'updatefound', f: () => void): void;
}

/** Watch a registration for a waiting worker. `hasController` is false on first install (nothing to update). */
export function watchRegistration(reg: RegLike, hasController: () => boolean): void {
  if (reg.waiting && hasController()) setWaiting(reg.waiting);
  reg.addEventListener('updatefound', () => {
    const w = reg.installing;
    if (!w) return;
    w.addEventListener('statechange', () => { if (w.state === 'installed' && hasController()) setWaiting(w); });
  });
}

/** Ask the waiting worker to activate; `reload` runs once the new worker controls the page. */
export function applyUpdate(container: Pick<ServiceWorkerContainer, 'addEventListener'> | undefined = typeof navigator !== 'undefined' ? navigator.serviceWorker : undefined, reload = () => location.reload()): boolean {
  const w = waitingWorker;
  if (!w || !container) return false;
  let done = false;
  container.addEventListener('controllerchange', () => { if (!done) { done = true; reload(); } });
  w.postMessage({ type: 'SKIP_WAITING' });
  return true;
}

export function _resetForTests() { waitingWorker = null; listeners.clear(); }
