import { useEffect } from 'react';

/** Route path (hash part, e.g. "#/specs" or "#/guides/x") → chunk loader. */
export type Loaders = Record<string, () => Promise<unknown>>;

/** Turn an anchor href ("#/specs?q=1", "./#/guides/x") into the route key used by `loaders`. */
export function routeOf(href: string | null): string | null {
  if (!href) return null;
  const i = href.indexOf('#/');
  if (i < 0) return null;
  const path = href.slice(i + 1).split(/[?#]/)[0];
  const seg = path.split('/').filter(Boolean);
  return seg.length ? `/${seg[0]}` : '/';
}

/** Dedupe-ing prefetcher: each chunk is requested at most once; failures are forgotten so a later hover retries. */
export function createPrefetcher(loaders: Loaders) {
  const done = new Map<string, Promise<unknown>>();
  return (href: string | null): boolean => {
    const r = routeOf(href);
    const f = r ? loaders[r] : undefined;
    if (!r || !f || done.has(r)) return false;
    done.set(r, f().catch(() => { done.delete(r); }));
    return true;
  };
}

const saveData = () => !!(navigator as unknown as { connection?: { saveData?: boolean } }).connection?.saveData;

/**
 * Prefetch route chunks on intent (hover, focus, touch) anywhere, and for links that scroll into view in the
 * current page (after the browser is idle). Respects Data Saver for the visibility-based prefetch.
 */
export function usePrefetch(pathname: string, loaders: Loaders) {
  useEffect(() => {
    const prefetch = createPrefetcher(loaders);
    const onIntent = (e: Event) => { const a = (e.target as Element | null)?.closest?.('a'); if (a) prefetch(a.getAttribute('href')); };
    const evs = ['pointerover', 'focusin', 'touchstart'] as const;
    evs.forEach((ev) => document.addEventListener(ev, onIntent, { passive: true }));
    let io: IntersectionObserver | null = null;
    let idle: number | null = null;
    if (typeof IntersectionObserver !== 'undefined' && !saveData()) {
      io = new IntersectionObserver((es) => es.forEach((x) => { if (x.isIntersecting) { prefetch((x.target as HTMLAnchorElement).getAttribute('href')); io?.unobserve(x.target); } }));
      const scan = () => document.querySelectorAll('main a[href^="#/"]').forEach((a) => io?.observe(a));
      idle = 'requestIdleCallback' in window ? requestIdleCallback(scan, { timeout: 3000 }) : (globalThis.setTimeout(scan, 1500) as unknown as number);
    }
    return () => {
      evs.forEach((ev) => document.removeEventListener(ev, onIntent));
      io?.disconnect();
      if (idle !== null) { if ('cancelIdleCallback' in window) cancelIdleCallback(idle); else clearTimeout(idle); }
    };
  }, [pathname, loaders]);
}
