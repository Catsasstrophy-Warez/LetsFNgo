import type { PartNumber } from './types';
import { LMR, MC_DCT, SUPP21, SUPP_NOTE } from './maintenance';

/**
 * Part numbers and fluid specs, seeded ONLY from facts already cited in maintenance.ts (rounds 1–5) plus the
 * round-6 Ford Performance part numbers. Slots stay empty where no source names a number (air/cabin filters,
 * brake pads, wipers…) — never fill them from memory.
 */
export const partNumbers: PartNumber[] = [
  { id: 'fl-2087', number: 'FL-2087', brand: 'Motorcraft', description: 'Engine oil filter', category: 'Filter', kind: 'part', maintenanceIds: ['oil-filter', 'oil-cap', 'oil-spec-supp'], reminderIds: ['r-oil'], source: LMR, confidence: 'reported', note: 'Also cited by the 2021 owner-manual supplement. One ALLDATA-sourced list says FL2062.' },
  { id: 'fl-500-s', number: 'FL-500-S', brand: 'Motorcraft', description: 'Oil filter (OE AA5Z-6714-A) named in a Mustang GT forum thread', category: 'Filter', kind: 'part', maintenanceIds: [], reminderIds: [], source: 'https://www.mustang7g.com/forums/threads/gt-oil-filter-part-number.158400/', confidence: 'unverified', note: 'Fitment caveat: not confirmed for the GT500 (round 6). Use FL-2087, the filter the 2021 supplement cites.' },
  { id: 'xt-14-l', number: 'XT-14-L', brand: 'Motorcraft', description: 'GT500 Dual Clutch Transmission Fluid (TR-9070)', category: 'Fluid', kind: 'part', maintenanceIds: ['dct-fluid', 'w-dct'], reminderIds: ['r-dct', 'r-dct-top'], source: MC_DCT, confidence: 'confirmed' },
  { id: 'xt-11-qdc', number: 'XT-11-QDC', brand: 'Motorcraft', description: 'Dry-clutch DCT fluid (WSS-M2C200-D2) — NOT for the GT500 TR-9070', category: 'Fluid', kind: 'avoid', maintenanceIds: ['dct-fluid'], reminderIds: ['r-dct', 'r-dct-top'], source: MC_DCT, confidence: 'confirmed' },
  { id: 'vc-13dl-g', number: 'VC-13DL-G', brand: 'Motorcraft', description: 'Yellow Prediluted coolant (engine 15.2 qt, intercooler 2.5 qt)', category: 'Fluid', kind: 'part', maintenanceIds: ['coolant', 'ic-coolant'], reminderIds: ['r-coolant'], source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'sp-581', number: 'SP-581', brand: 'Motorcraft', description: 'Spark plug, gap 0.037 ± 0.002 in (0.95 ± 0.05 mm)', category: 'Ignition', kind: 'part', maintenanceIds: ['plugs'], reminderIds: ['r-plugs'], source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'wss-m2c931-e1', number: 'WSS-M2C931-E1', brand: 'Ford spec', description: 'Engine oil spec: SAE 5W-50 full synthetic, API SP (current Motorcraft sheet)', category: 'Fluid spec', kind: 'spec', maintenanceIds: ['oil-type'], reminderIds: ['r-oil'], source: 'https://www.motorcraft.com/content/dam/ford-motorcraft/es_mx/inicio/ecatalog/pdf/f-t-sae-5W-50-full-synthetic-motor-oil.pdf', confidence: 'confirmed', note: 'The 2021 supplement prints WSS-M2C931-C.' },
  { id: 'wss-m97b57-a2', number: 'WSS-M97B57-A2', brand: 'Ford spec', description: 'Engine and intercooler coolant spec', category: 'Fluid spec', kind: 'spec', maintenanceIds: ['coolant', 'ic-coolant'], reminderIds: ['r-coolant'], source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'wss-m6c65-a2', number: 'WSS-M6C65-A2', brand: 'Ford spec', description: 'Brake fluid spec: Motorcraft DOT 4 LV High Performance', category: 'Fluid spec', kind: 'spec', maintenanceIds: ['brake-fluid'], reminderIds: ['r-brake'], source: SUPP21, confidence: 'reported', note: `${SUPP_NOTE} No Motorcraft part number for the fluid itself is sourced yet.` },
  { id: 'm-6766-a52', number: 'M-6766-A52', brand: 'Ford Performance', description: 'Oil separator (2020 GT500)', category: 'Performance part', kind: 'part', maintenanceIds: [], reminderIds: [], source: 'https://lmr.com/item/M6766A52/2020-gt500-ford-performance-oil-separator', confidence: 'reported', note: 'Round 6 (LMR listing).' },
  { id: 'm-16601-mcf', number: 'M-16601-MCF', brand: 'Ford Performance', description: 'Carbon fiber front splitter kit (2020–22 GT500)', category: 'Performance part', kind: 'part', maintenanceIds: [], reminderIds: [], source: 'https://performanceparts.ford.com/part/M-16601-MCF', confidence: 'reported', note: 'Round 6 (performanceparts.ford.com).' },
];

/** Items with no sourced part number yet (round 6 searched and found none). Shown as empty slots. */
export const partSlots = ['Engine air filter', 'Cabin air filter', 'Brake fluid (Motorcraft part number)', 'Brake pads & rotors', 'Wiper blades'];

export const partsForReminder = (reminderId: string) => partNumbers.filter((p) => p.reminderIds.includes(reminderId));
