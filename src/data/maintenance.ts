import type { MaintenanceItem } from './types';

const OM = 'https://www.ford.com/support/owner-manuals/'; // where to verify; figure not retrieved
const MISSING = 'Not sourced — needs the 2020–22 owner\'s manual and GT500 supplement.';

export const maintenance: MaintenanceItem[] = [
  { id: 'oil-type', item: 'Engine oil', value: 'Motorcraft SAE 5W-50 full synthetic (WSS-M2C931-E1, API SP)', source: 'https://www.motorcraft.com/content/dam/ford-motorcraft/es_mx/inicio/ecatalog/pdf/f-t-sae-5W-50-full-synthetic-motor-oil.pdf', confidence: 'confirmed' },
  { id: 'sump', item: 'Lubrication system', value: 'Wet sump', source: 'https://fordraptorforum.com/goto/post?id=2042984', confidence: 'reported' },
  { id: 'oil-cap', item: 'Engine oil capacity', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'dct-fluid', item: 'DCT fluid type & capacity', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'coolant', item: 'Engine coolant type & capacity', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'ic-coolant', item: 'Intercooler coolant', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'intervals', item: 'Service intervals', value: null, source: OM, confidence: 'unverified', note: MISSING },
  { id: 'break-in', item: 'Break-in', value: '100 mi before extended WOT; 1,000 mi before track use', source: 'https://www.mustang6g.com/forums/threads/gt500-break-in-period.127991/', confidence: 'unverified', note: 'From the 2014 GT500 supplement — not confirmed for 2020+.' },
  { id: 'warranty', item: 'Warranty', value: null, source: 'https://www.ford.com/support/warranty/', confidence: 'unverified', note: 'Presumably 3yr/36k basic and 5yr/60k powertrain, but unsourced — check Ford\'s Warranty Guide.' },
  { id: 'track-attack', item: 'GT500 Track Attack', value: 'Free for new buyers (travel extra), Ford Performance Racing School, Charlotte', source: 'https://fordauthority.com/2019/12/gt500-track-attack-is-free-to-all-2020-gt500-buyers/', confidence: 'confirmed' },
  { id: 'matching', item: 'Matching numbers', value: 'Last VIN digits are stamped on the block and transmission', source: 'https://www.saac.com/forum/index.php?msg=90658', confidence: 'reported' },
];
