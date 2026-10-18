/**
 * Pre-track checklist. Sourced items come only from records in src/data (each keeps its fact id, so the badge and
 * source link are read from the data, not copied). Tire pressures are a sourced item only once a Ford-sourced
 * pressure guide exists; until then the checklist asks for the owner's own target. Owner-added items are a template
 * on this device (`gt500.ptc.v1`); each Track session saves its own copy of the ticked list.
 */
import { maintenance } from '../data/maintenance';
import { guides } from '../data/guides';
import type { MaintenanceItem } from '../data/types';
import type { MsgKey } from './i18n';

import type { CheckItem } from './validate';
export type { CheckItem } from './validate';
export interface SourcedCheck { id: string; key: MsgKey; factId: string }

/** Items from the 2021 GT500 supplement's track-use schedule (and the break-in note, badged by its own confidence). */
export const SOURCED_CHECKS: SourcedCheck[] = [
  { id: 'ptc-brake-fluid', key: 'ptc.brakeFluid', factId: 'track-intervals' },
  { id: 'ptc-break-in', key: 'ptc.breakIn', factId: 'break-in' },
  { id: 'ptc-oil-after', key: 'ptc.oilAfter', factId: 'track-intervals' },
  { id: 'ptc-axle', key: 'ptc.axle', factId: 'diff-fluid' },
];

export const factFor = (id: string): MaintenanceItem | undefined => maintenance.find((m) => m.id === id);

/** True only when a ready guide with steps gives the GT500's tire pressures. */
export function tirePressuresSourced(): boolean {
  const g = guides.find((x) => x.id === 'tire-pressures');
  return !!g && g.status === 'ready' && g.steps.length > 0;
}

export { PTC_KEY, MAX_USER_ITEMS, MAX_ITEM_LEN, normPtc, loadPtc, savePtc, type PtcTemplate } from './ptc';
import { loadPtc, type PtcTemplate } from './ptc';

/** A fresh, unticked checklist: sourced items (labels in the current language), the tire item, then the owner's items. */
export function freshChecklist(tr: (k: MsgKey) => string, tpl: PtcTemplate = loadPtc()): CheckItem[] {
  return [
    ...SOURCED_CHECKS.filter((c) => factFor(c.factId)).map((c) => ({ id: c.id, label: tr(c.key), done: false, kind: 'sourced' as const, factId: c.factId })),
    { id: 'ptc-tires', label: tr(tirePressuresSourced() ? 'ptc.tiresSourced' : 'ptc.tiresOwn'), done: false, kind: 'user' as const },
    { id: 'ptc-noise', label: tr('ptc.noise'), done: false, kind: 'user' as const },
    ...tpl.items.map((label, i) => ({ id: `ptc-u${i}`, label, done: false, kind: 'user' as const })),
  ];
}

export { MAX_SAVED_ITEMS, normChecklist } from './validate';
