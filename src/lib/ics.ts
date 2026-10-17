import { reminderStatus, type Reminder } from './garage';

/**
 * RFC 5545 iCalendar export of maintenance reminders.
 * - TEXT values escape backslash, semicolon, comma and newlines (§3.3.11).
 * - Content lines are folded at 75 octets (UTF-8 bytes, never splitting a character) with CRLF + space (§3.1).
 * - Every line ends with CRLF. All-day events use DATE values; DTSTAMP is UTC.
 */
export const CRLF = '\r\n';

export function escapeText(s: string): string {
  // Control characters other than newlines are not allowed in TEXT values (they could break parsers): dropped.
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r\n|\r|\n/g, '\\n');
}

const enc = new TextEncoder();
/** Fold one content line so no physical line exceeds 75 octets. */
export function foldLine(line: string): string {
  if (enc.encode(line).length <= 75) return line;
  const out: string[] = [];
  let cur = '', bytes = 0, limit = 75;
  for (const ch of line) { // iterates code points, so surrogate pairs stay together
    const b = enc.encode(ch).length;
    if (bytes + b > limit) { out.push(cur); cur = ''; bytes = 0; limit = 74; } // continuation lines start with a space
    cur += ch; bytes += b;
  }
  out.push(cur);
  return out.join(`${CRLF} `);
}

const pad = (n: number) => String(n).padStart(2, '0');
export const icsDate = (iso: string) => iso.slice(0, 10).replace(/-/g, '');
export const icsStamp = (d: Date) => `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
const nextDay = (iso: string) => { const d = new Date(`${iso.slice(0, 10)}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); };

export interface IcsCar { id: string; label: string; odometer: number | null; reminders: Reminder[] }
export interface IcsResult { ics: string; events: number; skipped: string[] }

/**
 * One all-day VEVENT per reminder that has a due date. Overdue items are placed on `today` (marked overdue).
 * Mileage-only reminders cannot be put on a calendar and are returned in `skipped`.
 */
export function remindersToIcs(cars: IcsCar[], today: string, stamp = new Date()): IcsResult {
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//GT500 Companion//Maintenance reminders//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH', `X-WR-CALNAME:${escapeText('GT500 maintenance')}`];
  const skipped: string[] = [];
  let events = 0;
  const multi = cars.length > 1;
  for (const car of cars) {
    for (const r of car.reminders) {
      const st = reminderStatus(r, car.odometer, today);
      const name = multi ? `${car.label}: ${r.item}` : r.item;
      if (!st.dueDate) { skipped.push(name); continue; }
      const overdue = st.dueDate < today;
      const day = overdue ? today : st.dueDate;
      const desc = [
        overdue ? `Overdue since ${st.dueDate}.` : `Due by ${st.dueDate}.`,
        st.dueMiles !== null ? `Or at ${st.dueMiles.toLocaleString('en-US')} mi, whichever comes first.` : '',
        r.lastDate ? `Last done ${r.lastDate}${r.lastMiles !== null ? ` at ${r.lastMiles.toLocaleString('en-US')} mi` : ''}.` : '',
        'Owner-set interval from GT500 Companion; verify against your owner manual.',
      ].filter(Boolean).join('\n');
      lines.push('BEGIN:VEVENT',
        `UID:${escapeText(`${car.id}-${r.id}-${icsDate(st.dueDate)}`)}@gt500-companion`,
        `DTSTAMP:${icsStamp(stamp)}`,
        `DTSTART;VALUE=DATE:${icsDate(day)}`,
        `DTEND;VALUE=DATE:${icsDate(nextDay(day))}`,
        `SUMMARY:${escapeText(`${overdue ? 'Overdue: ' : ''}${name}`)}`,
        `DESCRIPTION:${escapeText(desc)}`,
        'TRANSP:TRANSPARENT',
        'END:VEVENT');
      events++;
    }
  }
  lines.push('END:VCALENDAR');
  return { ics: lines.map(foldLine).join(CRLF) + CRLF, events, skipped };
}
