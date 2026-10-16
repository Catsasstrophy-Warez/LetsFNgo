import { load, save } from './storage';
import { tr } from './i18n';
import { DEFAULT_NOTIFY, normNotify, type NotifyPrefs } from './validate';
import { DEFAULT_CAR_ID, carLabel, loadCars, reminderStatus, toNum, today, type Reminder } from './garage';

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
export function dueAlerts(rs: Reminder[], odometer: number | null, now: string, sent: Record<string, string>, car?: { id: string; label: string }): DueAlert[] {
  // Car #1 keeps the plain reminder id as its key so single-car history carries over; other cars are prefixed.
  const keyOf = (rid: string) => (!car || car.id === DEFAULT_CAR_ID ? rid : `${car.id}:${rid}`);
  return rs.flatMap((r) => {
    const id = keyOf(r.id);
    const s = reminderStatus(r, odometer, now);
    if (s.state !== 'overdue' && s.state !== 'soon') return [];
    const key = `${s.state}|${s.dueMiles ?? ''}|${s.dueDate ?? ''}`;
    if (sent[id] === key) return [];
    const when = [s.dueMiles !== null && `${s.dueMiles.toLocaleString('en-US')} mi`, s.dueDate].filter(Boolean).join(' · ');
    return [{ id, key, title: `${s.state === 'overdue' ? tr('notify.overdue') : tr('notify.soon')}: ${car?.label ? `${car.label} — ` : ''}${r.item}`, body: when ? tr('notify.due', { w: when }) : tr('notify.open') }];
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
  const store = loadCars();
  const multi = store.cars.length > 1;
  const alerts = store.cars.flatMap((c, i) => dueAlerts(c.reminders, toNum(c.odometer), today(), prefs.sent, multi ? { id: c.id, label: carLabel(c, i) } : { id: c.id, label: '' }));
  const sent = { ...prefs.sent };
  // Forget reminders (and cars) that no longer exist.
  const live = new Set(store.cars.flatMap((c) => c.reminders.map((r) => (c.id === DEFAULT_CAR_ID ? r.id : `${c.id}:${r.id}`))));
  for (const k of Object.keys(sent)) if (!live.has(k)) delete sent[k];
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
