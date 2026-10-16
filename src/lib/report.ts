import { recalls, NHTSA_LOOKUP } from '../data/recalls';
import { colors } from '../data/colors';
import type { RecallIssue } from '../data/types';
import { carOf, toNum, type Car, type LogEntry } from './garage';
import type { FillUp } from './fuel';
import { fmtQty, type Units } from './units';
import type { MsgKey } from './i18n';

/**
 * Resale service-history report for one car. Everything comes from what the owner typed into the app;
 * nothing is verified, and the report says so. Recall rows are a checklist, not a status lookup.
 */
export type VinMode = 'full' | 'last6' | 'none';
export interface OdoReading { date: string; miles: number; from: 'service' | 'mod' | 'fuel' | 'reminder' }
export interface ReportModel {
  generated: string;
  title: string; year: string; colorName: string; vin: string; odometer: number | null;
  service: LogEntry[]; mods: LogEntry[];
  serviceSpend: number; modSpend: number;
  recalls: RecallIssue[];
  odometerHistory: OdoReading[];
  /** Readings that go backwards in time order (a typo or a rollback; worth a look). */
  odometerWarnings: string[];
  nhtsaUrl: string;
}

const money = (s?: string) => { const n = Number(String(s ?? '').replace(/[$,\s]/g, '')); return s && s.trim() && Number.isFinite(n) ? n : 0; };
const ISO = /^\d{4}-\d{2}-\d{2}$/;

/** Does a recall's `years` field ("2020", "2021-2022", "2020-2022") cover a model year? Missing years = all. */
export function coversYear(years: string | undefined, year: string): boolean {
  if (!years || !year) return true;
  const m = /^(\d{4})(?:-(\d{4}))?$/.exec(years.trim());
  if (!m) return true;
  const lo = Number(m[1]), hi = Number(m[2] ?? m[1]), y = Number(year);
  return y >= lo && y <= hi;
}

/** Recalls and service campaigns to check for this car: excludes owner reports/claims and ones that do not apply to the GT500. */
export const recallChecklist = (year: string): RecallIssue[] =>
  recalls.filter((r) => (r.kind === 'recall' || r.kind === 'nhtsa-recall' || r.kind === 'service-action') && r.appliesToGT500 !== 'no' && coversYear(r.years, year));

export const maskVin = (vin: string, mode: VinMode) => (mode === 'none' || !vin ? '' : mode === 'last6' ? `•••••••••••${vin.slice(-6)}` : vin);

export function buildReport(car: Car, fuel: FillUp[], generated: string, vinMode: VinMode = 'full'): ReportModel {
  const byDate = (a: LogEntry, b: LogEntry) => a.date.localeCompare(b.date);
  const service = [...car.service].sort(byDate), mods = [...car.mods].sort(byDate);
  const readings: OdoReading[] = [];
  for (const e of service) { const m = toNum(e.miles ?? ''); if (m !== null && m >= 0 && ISO.test(e.date)) readings.push({ date: e.date, miles: m, from: 'service' }); }
  for (const e of mods) { const m = toNum(e.miles ?? ''); if (m !== null && m >= 0 && ISO.test(e.date)) readings.push({ date: e.date, miles: m, from: 'mod' }); }
  for (const f of fuel.filter((x) => carOf(x) === car.id)) if (ISO.test(f.date) && f.odometer >= 0) readings.push({ date: f.date, miles: f.odometer, from: 'fuel' });
  for (const r of car.reminders) if (r.lastMiles !== null && r.lastMiles >= 0 && ISO.test(r.lastDate)) readings.push({ date: r.lastDate, miles: r.lastMiles, from: 'reminder' });
  readings.sort((a, b) => a.date.localeCompare(b.date) || a.miles - b.miles);
  const warnings: string[] = [];
  let max = -1, maxDate = '';
  for (const r of readings) { if (r.miles < max) warnings.push(`${r.date}: ${r.miles} < ${max} (${maxDate})`); if (r.miles > max) { max = r.miles; maxDate = r.date; } }
  const c = colors.find((x) => x.id === car.color);
  return {
    generated, title: car.nickname.trim() || 'GT500', year: car.year, colorName: c?.name ?? (car.color === 'other' ? 'Other' : ''),
    vin: maskVin(car.vin, vinMode), odometer: toNum(car.odometer),
    service, mods, serviceSpend: service.reduce((s, e) => s + money(e.cost), 0), modSpend: mods.reduce((s, e) => s + money(e.cost), 0),
    recalls: recallChecklist(car.year), odometerHistory: readings, odometerWarnings: warnings, nhtsaUrl: NHTSA_LOOKUP,
  };
}

export const escapeHtml = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

type T = (k: MsgKey, v?: Record<string, string | number>) => string;
const usd = (n: number) => `$${n.toLocaleString('en-US', { maximumFractionDigits: 2 })}`;

/** A self-contained, printable HTML document (inline CSS, no scripts, no external requests). Every value is escaped. */
export function reportHtml(m: ReportModel, t: T, u: Units, lang: string): string {
  const e = escapeHtml;
  const dist = (n: number | null) => (n === null ? '—' : e(fmtQty('distance', n, u)));
  const logRows = (xs: LogEntry[]) => xs.length
    ? xs.map((x) => `<tr><td>${e(x.date)}</td><td>${e(x.title)}${x.notes ? `<div class="n">${e(x.notes)}</div>` : ''}</td><td>${dist(toNum(x.miles ?? ''))}</td><td>${x.cost ? e(`$${x.cost}`) : '—'}</td></tr>`).join('')
    : `<tr><td colspan="4">${e(t('report.none'))}</td></tr>`;
  const head = `<tr><th>${e(t('log.date'))}</th><th>${e(t('report.work'))}</th><th>${e(t('log.odometer'))}</th><th>${e(t('log.cost'))}</th></tr>`;
  const recallRows = m.recalls.map((r) => `<tr><td class="box">☐</td><td>${e(r.campaign ?? '')}</td><td>${e(r.title)}<div class="n">${e(r.buildWindow ? `${t('report.build')}: ${r.buildWindow}` : '')}</div></td><td>${e(r.appliesToGT500 ? t(`report.applies.${r.appliesToGT500}` as MsgKey) : '—')}</td></tr>`).join('');
  const odoRows = m.odometerHistory.length
    ? m.odometerHistory.map((r) => `<tr><td>${e(r.date)}</td><td>${dist(r.miles)}</td><td>${e(t(`report.from.${r.from}` as MsgKey))}</td></tr>`).join('')
    : `<tr><td colspan="3">${e(t('report.none'))}</td></tr>`;
  return `<!doctype html>
<html lang="${e(lang)}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${e(t('report.docTitle', { car: m.title }))}</title>
<style>
body{font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#111;background:#fff;max-width:900px;margin:24px auto;padding:0 16px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 6px;border-bottom:2px solid #c8102e;padding-bottom:2px}
table{width:100%;border-collapse:collapse;margin:6px 0}th,td{border:1px solid #bbb;padding:4px 6px;text-align:left;vertical-align:top}th{background:#f2f2f2}
.n{color:#444;font-size:12px;white-space:pre-wrap}.box{font-size:18px;width:28px;text-align:center}.disc{border:2px solid #111;padding:8px 10px;margin:12px 0;font-weight:600}
.meta td:first-child{width:30%;font-weight:600}.warn{color:#8a4b00}@media print{body{margin:0}h2{break-after:avoid}tr{break-inside:avoid}}
</style></head><body>
<h1>${e(t('report.docTitle', { car: m.title }))}</h1>
<p>${e(t('report.generated', { d: m.generated }))}</p>
<p class="disc">${e(t('report.disclaimer'))}</p>
<table class="meta"><tbody>
<tr><td>${e(t('garage.year'))}</td><td>${e(m.year || '—')}</td></tr>
<tr><td>${e(t('garage.color'))}</td><td>${e(m.colorName || '—')}</td></tr>
<tr><td>VIN</td><td>${e(m.vin || t('report.vinOmitted'))}</td></tr>
<tr><td>${e(t('garage.odometer'))}</td><td>${dist(m.odometer)}</td></tr>
<tr><td>${e(t('report.totals'))}</td><td>${e(t('report.totalsText', { svc: usd(m.serviceSpend), mods: usd(m.modSpend) }))}</td></tr>
</tbody></table>
<h2>${e(t('garage.serviceLog'))} (${m.service.length})</h2><table><thead>${head}</thead><tbody>${logRows(m.service)}</tbody></table>
<h2>${e(t('garage.modsLog'))} (${m.mods.length})</h2><table><thead>${head}</thead><tbody>${logRows(m.mods)}</tbody></table>
<h2>${e(t('report.odoTitle'))}</h2><table><thead><tr><th>${e(t('log.date'))}</th><th>${e(t('log.odometer'))}</th><th>${e(t('report.fromCol'))}</th></tr></thead><tbody>${odoRows}</tbody></table>
${m.odometerWarnings.length ? `<p class="warn">${e(t('report.odoWarn'))} ${e(m.odometerWarnings.join('; '))}</p>` : ''}
<h2>${e(t('report.recallTitle'))}</h2>
<p>${e(t('report.recallText'))} <a href="${e(m.nhtsaUrl)}">${e(m.nhtsaUrl)}</a></p>
<table><thead><tr><th>✓</th><th>${e(t('report.campaign'))}</th><th>${e(t('report.issue'))}</th><th>${e(t('report.appliesCol'))}</th></tr></thead><tbody>${recallRows}</tbody></table>
<p class="disc">${e(t('report.disclaimer'))}</p>
<p class="n">GT500 Companion · ${e(t('chrome.footer'))}</p>
</body></html>
`;
}
