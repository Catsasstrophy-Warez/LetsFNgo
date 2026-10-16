import { useEffect, useRef, useState, type ReactNode } from 'react';

/**
 * Renders `children` only once the placeholder scrolls near the viewport, so below-the-fold work (SVG charts,
 * long lists) stays off the first paint. The placeholder reserves `minHeight` so nothing shifts.
 * Without IntersectionObserver (old browsers, server render in tests) children render immediately.
 */
export function LazyRender({ children, minHeight, label }: { children: ReactNode; minHeight: number; label?: string }) {
  const [show, setShow] = useState(() => typeof IntersectionObserver === 'undefined');
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (show || !ref.current) return;
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { setShow(true); io.disconnect(); } }, { rootMargin: '200px 0px' });
    io.observe(ref.current);
    return () => io.disconnect();
  }, [show]);
  if (show) return <>{children}</>;
  return <div ref={ref} className="lazy-ph" style={{ minHeight }} aria-busy="true">{label && <p className="muted small">{label}</p>}</div>;
}
