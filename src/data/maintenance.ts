import type { MaintenanceItem } from './types';

const OM = 'https://www.ford.com/support/owner-manuals/'; // where to verify; figure not retrieved
const MISSING = 'Not sourced — needs the 2020–22 owner\'s manual and GT500 supplement.';
const LMR = 'https://lmr.com/products/2020-2022-shelby-gt500-oil-change-oil-life-reset';
const MC_DCT = 'https://www.motorcraft.com/us/en_us/home/our-products/chemicals-and-lubricants/transmission-fluid/gt500-dual-clutch-transmission-fluids.html';
const AG = 'https://AutoGuide.com/buyers-guide/ford-warranty/';

export const maintenance: MaintenanceItem[] = [
  { id: 'oil-type', group: 'Fluids', item: 'Engine oil', value: 'Motorcraft SAE 5W-50 full synthetic (WSS-M2C931-E1, API SP)', source: 'https://www.motorcraft.com/content/dam/ford-motorcraft/es_mx/inicio/ecatalog/pdf/f-t-sae-5W-50-full-synthetic-motor-oil.pdf', confidence: 'confirmed' },
  {
    id: 'oil-cap', group: 'Fluids', item: 'Engine oil capacity', value: '10–11.5', unit: 'qt', source: LMR, confidence: 'unverified',
    note: 'Sources conflict; check the owner\'s manual before relying on any figure.',
    conflicts: [
      { value: '11.5 qt (Motorcraft FL-2087 filter)', source: LMR, confidence: 'reported', context: 'Most-cited (LMR)' },
      { value: '11 qt pan', source: LMR, confidence: 'unverified', context: 'Ford media material, per LMR summary' },
      { value: '10 qt (FL2062 filter)', source: 'https://lmr.com/products/mustang-fluid-capacity-2018-2020', confidence: 'unverified', context: 'ALLDATA list via search snippet' },
    ],
  },
  { id: 'oil-filter', group: 'Fluids', item: 'Oil filter', value: 'Motorcraft FL-2087', source: LMR, confidence: 'reported', note: 'One ALLDATA-sourced list says FL2062.' },
  { id: 'sump', group: 'Fluids', item: 'Lubrication system', value: 'Wet sump', source: 'https://fordraptorforum.com/goto/post?id=2042984', confidence: 'reported' },
  {
    id: 'dct-fluid', group: 'Fluids', item: 'DCT fluid', value: 'Motorcraft XT-14-L GT500 Dual Clutch Transmission Fluid', source: MC_DCT, confidence: 'confirmed',
    warning: 'XT-11-QDC (WSS-M2C200-D2) is a dry-clutch fluid and is NOT correct for the GT500 TR-9070.',
  },
  { id: 'dct-cap', group: 'Fluids', item: 'DCT fluid capacity', value: '8.0 qt total (drain/fill ≈ 3–4 qt per owners)', source: LMR, confidence: 'unverified', note: 'ALLDATA via LMR; not confirmed by Ford.' },
  { id: 'coolant', group: 'Fluids', item: 'Engine coolant type & capacity', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'ic-coolant', group: 'Fluids', item: 'Intercooler coolant', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'diff-fluid', group: 'Fluids', item: 'Rear differential fluid', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'brake-fluid', group: 'Fluids', item: 'Brake fluid', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'plugs', group: 'Fluids', item: 'Spark plug gap', value: '≈ 0.035–0.039', unit: 'in', source: 'https://lmr.com/products/2015-2025-mustang-spark-plug-gap-specs', confidence: 'unverified', note: 'From a search snippet (page blocked); column alignment uncertain. Plug part number not found — check the owner\'s manual.' },
  { id: 'intervals', group: 'Service', item: 'Oil change interval', value: 'Intelligent Oil-Life Monitor', source: LMR, confidence: 'reported', note: 'Maximum interval not found.' },
  { id: 'first-oil', group: 'Service', item: 'First oil change (owner practice)', value: '500–1,000 mi', source: 'https://forums.shelby.com/topic/46409-first-oil-change/', confidence: 'unverified' },
  { id: 'break-in', group: 'Service', item: 'Break-in', value: '100 mi before extended WOT; 1,000 mi before track use', source: 'https://www.mustang6g.com/forums/threads/gt500-break-in-period.127991/', confidence: 'unverified', note: 'From the 2014 GT500 supplement — not confirmed for 2020+.' },
  { id: 'w-b2b', group: 'Warranty', item: 'Bumper-to-bumper', value: '3 yr / 36,000 mi', source: AG, confidence: 'reported', note: 'Ford standard terms; no GT500-specific warranty guide retrieved.' },
  { id: 'w-pt', group: 'Warranty', item: 'Powertrain', value: '5 yr / 60,000 mi', source: AG, confidence: 'reported' },
  { id: 'w-corr', group: 'Warranty', item: 'Corrosion (perforation)', value: '5 yr / unlimited mi', source: AG, confidence: 'reported' },
  { id: 'w-corr2', group: 'Warranty', item: 'Corrosion (non-perforating)', value: '3 yr / 36,000 mi', source: 'https://www.consumerreports.org/money/warranties-guarantees/your-guide-to-car-warranties-a1088768196/', confidence: 'reported' },
  { id: 'w-dct', group: 'Warranty', item: 'DCT fluid & warranty', value: 'XT-14-L "meets all powertrain warranty requirements"', source: MC_DCT, confidence: 'confirmed' },
  { id: 'w-emis', group: 'Warranty', item: 'Emissions warranty', value: null, source: 'https://www.ford.com/support/warranty/', confidence: 'unverified', note: 'Federal 8 yr/80k on major components is standard, but not verified for this car.' },
  { id: 'w-cf', group: 'Warranty', item: 'Carbon fiber wheels coverage / track use', value: null, source: 'https://www.ford.com/support/warranty/', confidence: 'unverified', note: 'Not sourced.' },
  { id: 'matching', group: 'Ownership', item: 'Matching numbers', value: 'Last VIN digits are stamped on the block and transmission', source: 'https://www.saac.com/forum/index.php?msg=90658', confidence: 'reported' },
];
