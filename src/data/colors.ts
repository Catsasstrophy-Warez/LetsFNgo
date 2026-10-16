import type { PaintColor } from './types';

const FA20 = 'https://fordauthority.com/2019/09/2020-ford-mustang-shelby-gt500-colors/';
const MA21 = 'https://www.mustangattitude.com/mustang/2021shelby.shtml';
const MA22 = 'https://www.mustangattitude.com/mustang/2022shelby.shtml';
const SC21 = 'https://www.supercars.net/blog/ford-updates-the-mustang-and-shelby-gt500-for-2021-model-year';
const CARRY = '2021–22 carryover not confirmed (full later palettes not retrieved).';

/**
 * Paint colors. 2020 list (11 colors) and codes from Ford Authority via search snippet;
 * 2021/2022 additions from MustangAttitude snippets (sourced from paintref).
 * Round-1 guesses "Grabber Lime = PP" and "Twister Orange = KU" were wrong (F9 and CA).
 * Swatches are approximate display colors only.
 */
export const colors: PaintColor[] = [
  { id: 'twister-orange', name: 'Twister Orange Tri-Coat', code: 'CA (M7434)', swatch: '#e2601c', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported', note: 'Extra-cost color ($495 or $395 — which price applies is ambiguous).' },
  { id: 'rapid-red', name: 'Rapid Red Metallic Tinted Clearcoat', code: 'D4', swatch: '#8e1018', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported', note: 'Extra-cost color ($495 or $395 — ambiguous).' },
  { id: 'velocity-blue', name: 'Velocity Blue', code: 'E7', swatch: '#1d4fa3', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported' },
  { id: 'grabber-lime', name: 'Grabber Lime', code: 'F9 (M7435)', swatch: '#9ccc2a', years: [2020], source: FA20, confidence: 'reported', note: 'Dropped for 2021. Not "PP" as guessed in round 1.' },
  { id: 'performance-blue', name: 'Ford Performance Blue', code: 'FM (M7412)', swatch: '#1f5fb8', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported', note: 'GT500-exclusive per MustangAttitude. Listed as "Fast Pitch Blue" in one forum tally.' },
  { id: 'shadow-black', name: 'Shadow Black', code: 'G1', swatch: '#111214', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported' },
  { id: 'magnetic', name: 'Magnetic', code: 'J7', swatch: '#55585c', years: [2020], source: FA20, confidence: 'reported', note: 'Dropped for 2021.' },
  { id: 'iconic-silver', name: 'Iconic Silver', code: 'JS', swatch: '#b9bcbf', years: [2020, 2022], yearsNote: '2022 seen on a PCARMarket car; 2021 not confirmed.', source: FA20, confidence: 'reported' },
  { id: 'kona-blue', name: 'Kona Blue', code: 'L6', swatch: '#1f3f8f', years: [2020], source: FA20, confidence: 'reported', note: 'Dropped for 2021.' },
  { id: 'race-red', name: 'Race Red', code: 'PQ', swatch: '#d0121b', years: [2020], yearsNote: CARRY, source: FA20, confidence: 'reported' },
  { id: 'oxford-white', name: 'Oxford White', code: 'YZ', swatch: '#f7f7f4', years: [2020, 2021], yearsNote: '2021 seen on a Barrett-Jackson car; 2022 not confirmed.', source: FA20, confidence: 'reported' },
  { id: 'wimbledon-white', name: 'Wimbledon White', code: 'N4', swatch: '#f1efe6', years: [2022], source: SC21, confidence: 'unverified', note: 'Round 1 says it was dropped as a body color for 2021, but it is not in the 11-color 2020 list. Used for 2022 Heritage Edition stripes. Code N4 is unverified for the GT500 (round 7): PaintScratch lists "Wimbledon White N4" only for 2015, 2025 and 2026 Mustangs, not 2020–2022 (https://shop.paintscratch.com/colors/ford/wimbledon-white-n4). 9A is the 1960s code.' },
  { id: 'grabber-yellow', name: 'Grabber Yellow', code: 'CB (M7451)', swatch: '#f2c500', years: [2021], yearsNote: 'Added for 2021; 2022 not confirmed.', source: MA21, confidence: 'reported' },
  { id: 'antimatter-blue', name: 'Antimatter Blue Metallic', code: 'HX (M7456)', swatch: '#1b2433', years: [2021], yearsNote: 'Added for 2021; 2022 not confirmed.', source: MA21, confidence: 'reported' },
  { id: 'carbonized-gray', name: 'Carbonized Gray Metallic', code: 'M7 (M7458)', swatch: '#4a4d50', years: [2021], yearsNote: 'Added for 2021; 2022 not confirmed.', source: MA21, confidence: 'confirmed' },
  { id: 'dark-matter-gray', name: 'Dark Matter Gray', code: 'HY', swatch: '#3a3d40', years: [2022], yearsNote: 'Seen on a 2022 PCARMarket car only.', source: 'https://fordauthority.com/2022/05/2022-ford-mustang-gains-new-dark-matter-gray-metallic-color-first-look', confidence: 'reported', note: `Order code HY (Ford Authority; also Steeda). Manufacturer code M7470 is from a PaintScratch search snippet only (unverified). GT500 presence: PCARMarket 2022 car.` },
  { id: 'code-orange', name: 'Code Orange', code: 'CN (M7468)', swatch: '#ff6a13', years: [2022], source: MA22, confidence: 'reported', note: 'Added for 2022; Ford Performance-exclusive.' },
  { id: 'eruption-green', name: 'Eruption Green', code: 'FA', swatch: '#2f5a3a', years: [2022], source: 'https://www.steeda.com/2022-mustang-paint-colors-codes', confidence: 'reported', note: 'Order code FA (Steeda 2022 table; Ford Authority). Manufacturer code M7476 is from a PaintScratch search snippet only (unverified).' },
  { id: 'brittany-blue', name: 'Brittany Blue', code: 'EB', swatch: '#7fa7b8', years: [2022], source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed', note: 'Heritage Edition only. Code EB is from Steeda\'s 2022 table only (reported, single source; no manufacturer code found).' },
];
