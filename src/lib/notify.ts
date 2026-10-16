import { load, save } from './storage';
import { DEFAULT_NOTIFY, normNotify, type NotifyPrefs } from './validate';
import { loadGarage, reminderStatus, toNum, today, type Reminder } from './garage';

export const NOTIFY_KEY = 'gt500.notify.v1';
export const loadNotify = (): NotifyPrefs => normNotify(load<unknown>(NOTIFY_KEY, null)) ?? { ...DEFAULT_NOTIFY, sent: {} };
export const saveNotify = (p: NotifyPrefs) => save(NOTIFY_KEY, p);

export type Support = 'unsupported' | 'default' | 'granted' | 'denied';
export function notifySupport(): Support {
  if (typeof window === 'undefined' || !('Notification' in window)) return 'unsupported';
  return Notification.permission as Support;
}

export interface DueAlert { id: string; key: string; title: string; body: string }

/**
 * Reminders that are due soon or overdue and not yet announced for this due point.
 * The key changes when the reminder is serviced (new due miles/date), so it can fire again next cycle.
 */
export function dueAlerts(rs: Reminder[], odometer: number | null, now: string, sent: Record<string, string>): DueAlert[] {
  return rs.flatMap((r) => {
    const s = reminderStatus(r, odometer, now);
    if (s.state !== 'overdue' && s.state !== 'soon') return [];
    const key = `${s.state}|${s.dueMiles ?? ''}|${s.dueDate ?? ''}`;
    if (sent[r.id] === key) return [];
    const when = [s.dueMiles !== null && `${s.dueMiles.toLocaleString('en-US')} mi`, s.dueDate].filter(Boolean).join(' · ');
    return [{ id: r.id, key, title: `${s.state === 'overdue' ? 'Overdue' : 'Due soon'}: ${r.item}`, body: when ? `Due ${when}. Open the Garage to log the service.` : 'Open the Garage to log the service.' }];
  });
}

/** Show a notification through the service worker (required on Android), falling back to the page API. */
async function show(a: DueAlert): Promise<boolean> {
  const opts = { body: a.body, tag: `gt500-${a.id}`, icon: './icon.svg' };
  try {
    const reg = 'serviceWorker' in navigator ? await navigator.serviceWorker.getRegistration() : undefined;
    if (reg) { await reg.showNotification(a.title, opts); return true; }
    new Notification(a.title, opts);
    return true;
  } catch { return false; }
}

/** Called on app open. Does nothing unless enabled and permission is granted. Returns how many were shown. */
export async function checkReminders(): Promise<number> {
  const prefs = loadNotify();
  if (!prefs.enabled || notifySupport() !== 'granted') return 0;
  const g = loadGarage();
  const alerts = dueAlerts(g.reminders, toNum(g.odometer), today(), prefs.sent);
  const sent = { ...prefs.sent };
  // Forget reminders that no longer exist.
  for (const k of Object.keys(sent)) if (!g.reminders.some((r) => r.id === k)) delete sent[k];
  let n = 0;
  for (const a of alerts) if (await show(a)) { sent[a.id] = a.key; n++; }
  saveNotify({ ...prefs, sent });
  return n;
}

/** Ask for permission (must come from a tap). Returns the resulting state. */
export async function requestPermission(): Promise<Support> {
  if (notifySupport() === 'unsupported') return 'unsupported';
  try { return (await Notification.requestPermission()) as Support; } catch { return notifySupport(); }
}
