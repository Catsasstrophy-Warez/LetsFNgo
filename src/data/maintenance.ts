import type { MaintenanceItem } from './types';

export const LMR = 'https://lmr.com/products/2020-2022-shelby-gt500-oil-change-oil-life-reset';
export const MC_DCT = 'https://www.motorcraft.com/us/en_us/home/our-products/chemicals-and-lubricants/transmission-fluid/gt500-dual-clutch-transmission-fluids.html';
/** 2021 Mustang (CZG) GT500 owner-manual supplement, edition 202012 — third-party copy; may not match 2020/2022. */
export const SUPP21 = 'https://autooutlet.cz/wp-content/uploads/2022/11/21-mustang-shelby-en.pdf';
export const SUPP_NOTE = 'From the 2021 GT500 owner-manual supplement (third-party copy); 2020 and 2022 supplements were not found.';
const AG = 'https://AutoGuide.com/buyers-guide/ford-warranty/';

export const maintenance: MaintenanceItem[] = [
  { id: 'oil-type', group: 'Fluids', item: 'Engine oil', value: 'Motorcraft SAE 5W-50 full synthetic (WSS-M2C931-E1, API SP)', source: 'https://fcsdchemicalsandlubricants.com/products/motor-oil/productdetails?id=69', note: 'Previous source URL: https://www.motorcraft.com/content/dam/ford-motorcraft/es_mx/inicio/ecatalog/pdf/f-t-sae-5W-50-full-synthetic-motor-oil.pdf', confidence: 'confirmed' },
  {
    id: 'oil-cap', group: 'Fluids', item: 'Engine oil capacity', value: '10–11.5', unit: 'qt', source: LMR, confidence: 'unverified',
    note: 'Sources conflict; check the owner\'s manual before relying on any figure.',
    conflicts: [
      { value: '11.5 qt (Motorcraft FL-2087 filter)', source: LMR, confidence: 'reported', context: 'Most-cited (LMR)' },
      { value: '11 qt pan', source: LMR, confidence: 'unverified', context: 'Ford media material, per LMR summary' },
      { value: '11.5 qt (2020 supplement per secondary sources)', source: LMR, confidence: 'unverified', context: 'Research round 16: parts/forum sources attribute it to the 2020 GT500 supplement; seen only in a search summary' },
      { value: '10 qt (FL2062 filter)', source: 'https://lmr.com/products/mustang-fluid-capacity-2018-2020', confidence: 'unverified', context: 'ALLDATA list via search snippet' },
    ],
  },
  { id: 'oil-filter', group: 'Fluids', item: 'Oil filter', value: 'Motorcraft FL-2087', source: LMR, confidence: 'reported', note: 'One ALLDATA-sourced list says FL2062.' },
  { id: 'oil-spec-supp', group: 'Fluids', item: 'Engine oil spec (supplement)', value: 'SAE 5W-50, WSS-M2C931-C · filter FL-2087', source: SUPP21, confidence: 'reported', note: `${SUPP_NOTE} Motorcraft's current 5W-50 sheet lists WSS-M2C931-E1 (above).` },
  { id: 'sump', group: 'Fluids', item: 'Lubrication system', value: 'Wet sump', source: 'https://fordraptorforum.com/goto/post?id=2042984', confidence: 'reported' },
  {
    id: 'dct-fluid', group: 'Fluids', item: 'DCT fluid', value: 'Motorcraft XT-14-L GT500 Dual Clutch Transmission Fluid', source: MC_DCT, confidence: 'confirmed',
    warning: 'XT-11-QDC (WSS-M2C200-D2) is a dry-clutch fluid and is NOT correct for the GT500 TR-9070.',
  },
  { id: 'dct-cap', group: 'Fluids', item: 'DCT fluid capacity', value: '8.0 qt total (drain/fill ≈ 3–4 qt per owners)', source: LMR, confidence: 'unverified', note: 'ALLDATA via LMR; not confirmed by Ford. Research round 16 found no Ford or Motorcraft capacity figure either.' },
  { id: 'coolant', group: 'Fluids', item: 'Engine coolant type & capacity', value: 'Motorcraft Yellow Prediluted VC-13DL-G (WSS-M97B57-A2) · 15.2 qt (14.4 L)', source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'ic-coolant', group: 'Fluids', item: 'Intercooler coolant', value: 'Motorcraft Yellow VC-13DL-G (WSS-M97B57-A2) · 2.5 qt (2.4 L)', source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'diff-fluid', group: 'Fluids', item: 'Rear differential fluid interval', value: 'Every 150,000 mi; every 500 mi of track use or on an axle over-temperature warning', source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'brake-fluid', group: 'Fluids', item: 'Brake fluid', value: 'Motorcraft DOT 4 LV High Performance (WSS-M6C65-A2) · change every 3 years', source: SUPP21, confidence: 'reported', note: `${SUPP_NOTE} The supplement also says to replace it before track use.` },
  {
    id: 'plugs', group: 'Fluids', item: 'Spark plugs', value: 'SP-581, gap 0.037 ± 0.002 in (0.95 ± 0.05 mm)', source: SUPP21, confidence: 'reported',
    note: `${SUPP_NOTE} Replace every 100,000 mi (round-5 re-extraction resolves the earlier 50k vs 100k ambiguity; 50k is the fuel filter).`,
    conflicts: [
      { value: 'SP-581, 0.037 in', source: SUPP21, confidence: 'reported', context: '2021 GT500 supplement' },
      { value: '≈ 0.035–0.039 in', source: 'https://lmr.com/products/2015-2025-mustang-spark-plug-gap-specs', confidence: 'unverified', context: 'Search snippet, column alignment uncertain' },
    ],
  },
  { id: 'intervals', group: 'Service', item: 'Oil change interval', value: 'Intelligent Oil-Life Monitor, max 1 yr / 10,000 mi (severe 3,000 mi)', source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'supp-intervals', group: 'Service', item: 'Normal service schedule (2021 supplement)', value: 'Oil & filter: oil-life monitor, max 1 yr / 10,000 mi (severe use 3,000 mi) · brake fluid 3 yr · cabin air filter 20k · DCT side filter + fluid top-off 20k · engine air filter 30k · DCT fluid + side filter 40k · fuel filter 50k · spark plugs 100k · differential fluid 150k · coolant first 10 yr / 200k, then every 5 yr / 100k', source: SUPP21, confidence: 'reported', note: `${SUPP_NOTE} Re-extracted with pdftotext -layout in round 5, which fixed the column alignment. The 20k service also inspects the intercooler, intercooler coolant and supercharger belt.` },
  { id: 'track-intervals', group: 'Service', item: 'Track-use service (2021 supplement)', value: 'Oil & filter after one track weekend or ≈ 4 hours · rear axle fluid every 500 mi of track use or on an over-temperature warning · replace brake fluid with DOT 4 LV (dry boiling point > 500 °F) before an event', source: SUPP21, confidence: 'reported', note: SUPP_NOTE },
  { id: 'first-oil', group: 'Service', item: 'First oil change (owner practice)', value: '500–1,000 mi', source: 'https://forums.shelby.com/topic/46409-first-oil-change/', confidence: 'unverified' },
  { id: 'break-in', group: 'Service', item: 'Break-in', value: '100 mi before extended WOT; 1,000 mi before track use', source: 'https://www.mustang6g.com/forums/threads/gt500-break-in-period.127991/', confidence: 'unverified', note: 'From the 2014 GT500 supplement — not confirmed for 2020+.' },
  { id: 'w-b2b', group: 'Warranty', item: 'Bumper-to-bumper', value: '3 yr / 36,000 mi', source: AG, confidence: 'reported', note: 'Ford standard terms; no GT500-specific warranty guide retrieved.' },
  { id: 'w-pt', group: 'Warranty', item: 'Powertrain', value: '5 yr / 60,000 mi', source: AG, confidence: 'reported' },
  { id: 'w-corr', group: 'Warranty', item: 'Corrosion (perforation)', value: '5 yr / unlimited mi', source: AG, confidence: 'reported' },
  { id: 'w-corr2', group: 'Warranty', item: 'Corrosion (non-perforating)', value: '3 yr / 36,000 mi', source: 'https://www.consumerreports.org/money/warranties-guarantees/your-guide-to-car-warranties-a1088768196/', confidence: 'reported' },
  { id: 'w-dct', group: 'Warranty', item: 'DCT fluid & warranty', value: 'XT-14-L "meets all powertrain warranty requirements"', source: MC_DCT, confidence: 'confirmed' },
  { id: 'w-emis', group: 'Warranty', item: 'Emissions warranty', value: null, source: 'https://www.ford.com/support/warranty/', confidence: 'unverified', note: 'Federal 8 yr/80k on major components is standard, but not verified for this car.' },
  { id: 'w-cf', group: 'Warranty', item: 'Carbon fiber wheels coverage / track use', value: null, source: 'https://www.ford.com/support/warranty/', confidence: 'unverified', note: 'Not sourced.' },
  { id: 'ins-motortrend', group: 'Ownership', item: 'Insurance data point: MotorTrend / Insure.com', value: 2488, unit: '$/yr', context: 'GT500 about $2,488/yr vs Camaro ZL1 $2,539 and Challenger Hellcat Redeye $3,282', source: 'https://fordauthority.com/2021/08/ford-mustang-gt-shelby-gt500-cheaper-to-insure-than-direct-rivals/', confidence: 'unverified', note: 'Research round 15, search summary only (page 403). Profile: 40-year-old single male, clean record, $500 deductible, full coverage; model year not stated. A reference point, not a quote.' },
  { id: 'ins-autoblog', group: 'Ownership', item: 'Insurance data point: Autoblog cost-of-ownership model', value: 1800, unit: '$/yr', context: '2020 GT500 coupe, year 1 (about $1,721 by year 5)', source: 'https://www.autoblog.com/buy/2020-Ford-Shelby+GT500-Base__2dr_Coupe/specs/', confidence: 'unverified', note: 'Research round 15, search summary only. A modeled estimate, not a quote.' },
  { id: 'matching', group: 'Ownership', item: 'Matching numbers', value: 'Last VIN digits are stamped on the block and transmission', source: 'https://www.saac.com/forum/index.php?msg=90658', confidence: 'reported' },
];
