import { load, save } from './storage';

/**
 * Custom PWA install prompt. Chromium fires `beforeinstallprompt`; we keep the event and show our own banner.
 * iOS Safari has no such event, so we show an "Add to Home Screen" hint instead. A dismissal is remembered on this
 * device (`gt500.install.v1`) for DISMISS_DAYS; installing or running standalone hides it for good.
 */
export const INSTALL_KEY = 'gt500.install.v1';
export const DISMISS_DAYS = 90;
export interface InstallState { dismissed: string | null }

export function loadInstall(): InstallState {
  const v = load<unknown>(INSTALL_KEY, null);
  const d = v && typeof v === 'object' && !Array.isArray(v) ? (v as { dismissed?: unknown }).dismissed : null;
  return { dismissed: typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d) ? d : null };
}
export const dismissInstall = (today: string) => save(INSTALL_KEY, { dismissed: today });

/** Still inside the remembered dismissal window? */
export function isDismissed(s: InstallState, today: string, days = DISMISS_DAYS): boolean {
  if (!s.dismissed) return false;
  const ms = Date.parse(`${today}T00:00:00Z`) - Date.parse(`${s.dismissed}T00:00:00Z`);
  return Number.isFinite(ms) && ms >= 0 && ms < days * 86_400_000;
}

/** iPhone/iPad Safari (incl. iPadOS that reports as Mac with touch), not other iOS browsers that cannot install. */
export function isIosSafari(ua: string, maxTouchPoints = 0): boolean {
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && maxTouchPoints > 1);
  return ios && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
}

/** Already running as an installed app. */
export function isStandalone(w: { matchMedia?: (q: string) => { matches: boolean }; navigator?: unknown } = typeof window !== 'undefined' ? window : {}): boolean {
  const nav = w.navigator as { standalone?: boolean } | undefined;
  return !!(w.matchMedia?.('(display-mode: standalone)').matches || nav?.standalone);
}

/** Which prompt (if any) to show. */
export function installMode(o: { hasPrompt: boolean; ios: boolean; standalone: boolean; native: boolean; dismissed: boolean }): 'prompt' | 'ios' | null {
  if (o.standalone || o.native || o.dismissed) return null;
  if (o.hasPrompt) return 'prompt';
  return o.ios ? 'ios' : null;
}
