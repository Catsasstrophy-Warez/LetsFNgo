/** True inside the Capacitor iOS/Android wrapper (the native bridge injects `window.Capacitor`). */
export function isNativeApp(w: unknown = typeof window !== 'undefined' ? window : undefined): boolean {
  const cap = (w as { Capacitor?: { isNativePlatform?: () => boolean } } | undefined)?.Capacitor;
  try { return !!cap?.isNativePlatform?.(); } catch { return false; }
}

/**
 * Service workers are skipped in the native wrapper: the assets already ship inside the app bundle, and WKWebView
 * (iOS) does not support service workers for the capacitor:// scheme.
 */
export const shouldRegisterSW = (w: unknown = typeof window !== 'undefined' ? window : undefined, nav: unknown = typeof navigator !== 'undefined' ? navigator : undefined) =>
  !!nav && typeof nav === 'object' && 'serviceWorker' in nav && !isNativeApp(w);
