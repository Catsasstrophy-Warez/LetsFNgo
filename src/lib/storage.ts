export function load<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

type Listener = (key: string) => void;
const failListeners = new Set<Listener>();
/** Subscribe to failed writes (quota exceeded, storage disabled). Returns an unsubscribe function. */
export function onSaveError(f: Listener): () => void { failListeners.add(f); return () => { failListeners.delete(f); }; }

/** Persist a value. Returns false (and notifies onSaveError listeners) when the browser refuses the write. */
export function save(key: string, value: unknown): boolean {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    failListeners.forEach((f) => f(key));
    return false;
  }
}

export function remove(key: string): void {
  try { localStorage.removeItem(key); } catch { /* ignore */ }
}
