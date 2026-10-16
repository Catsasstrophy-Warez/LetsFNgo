import type { FpCatalogItem, PartNumber } from './types';
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

/**
 * Ford Performance catalog (performanceparts.ford.com/search/GT500, fetched 2026-10-16, research round 8).
 * MSRPs are current prices on that date, not period prices. The catalog shows no per-part emissions status, so
 * `emissions` is null. Only the first six are listed for the 2020–22 GT500; the rest are inferred from part names.
 */
const FP = 'https://performanceparts.ford.com/search/GT500';
export const FP_AS_OF = '2026-10-16';
const AS_OF = FP_AS_OF;
export const FITMENT_INFERRED = 'Fitment inferred from the part name; not listed for the 2020-22 GT500 by the catalog. Confirm with Ford Performance before ordering.';
export const fpCatalog: FpCatalogItem[] = [
  { id: 'm-16612-c20', number: 'M-16612-C20', name: '2020-2022 GT500 Carbon Fiber Hood Vent Kit', msrp: 1360, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: true, category: 'Body & aero', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-16601-mcf', number: 'M-16601-MCF', name: '2020-2022 GT500 Carbon Fiber Front Splitter Kit', msrp: 1990, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: true, category: 'Body & aero', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-17750-mcf', number: 'M-17750-MCF', name: '2020-22 GT500 Carbon Fiber Bumper Insert', msrp: 1255, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: true, category: 'Body & aero', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-16600-mcf', number: 'M-16600-MCF', name: '2020-2022 GT500 Carbon Fiber Rear Deck Lid Trim Panel', msrp: 725, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: true, category: 'Body & aero', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-9926-m5292', number: 'M-9926-M5292', name: '2020-2021 GT500 Throttle Body 92MM', msrp: 475, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021], fitmentExplicit: true, category: 'Engine', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-6766-a52', number: 'M-6766-A52', name: '2020-2022 GT500 5.2L Oil-Air Separator', msrp: 625, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: true, category: 'Engine', source: FP, confidence: 'confirmed', research: 'high' },
  { id: 'm-6017-m52sc', number: 'M-6017-M52SC', name: '5.2L Mustang GT500 Engine Control Pack', msrp: 2730, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-6675-m52s', number: 'M-6675-M52S', name: '5.0L/5.2L GT500 Aluminum Oil Pan and Pump Kit', msrp: 1485, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-8501-m58', number: 'M-8501-M58', name: 'High Performance Intercooler Pump Kit, Cobra Jet/GT500', msrp: 415, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Fuel & cooling', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-3a331-gt500a', number: 'M-3A331-GT500A', name: 'GT500 LH Inner Half Shaft Seal', msrp: 180, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Driveline', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-1620001-hatbw', number: 'M-1620001-HATBW', name: 'Mustang Shelby GT500 Underhood Rain Hat Graphic', msrp: 65, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Appearance', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-6564-m52a', number: 'M-6564-M52A', name: '5.2L Predator Roller Finger Follower Kit', msrp: 600, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-9407-m52sc', number: 'M-9407-M52SC', name: 'High Performance Dual Fuel Pump Kit', msrp: 220, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Fuel & cooling', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-12029-m52', number: 'M-12029-M52', name: '5.0L/5.2L Hi-Energy Engine Ignition Coils (8)', msrp: 645, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-6500-m50r', number: 'M-6500-M50R', name: '2011-2024 5.0L/5.2L Coyote High Performance Lash Adjusters', msrp: 475, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-6303-m52b', number: 'M-6303-M52B', name: 'Coyote 5.2L Forged Crankshaft', msrp: 1440, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Engine', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-16600-fp', number: 'M-16600-FP', name: '2015-23 Mustang Rear Spoiler w/ Gurney Flap', msrp: 700, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Body & aero', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
  { id: 'm-4130-ma', number: 'M-4130-MA', name: '2015-2026 Mustang Half Shaft Upgrade Kit', msrp: 2575, priceAsOf: AS_OF, emissions: null, fitmentYears: [2020, 2021, 2022], fitmentExplicit: false, category: 'Driveline', source: FP, confidence: 'reported', research: 'medium', note: FITMENT_INFERRED },
];
