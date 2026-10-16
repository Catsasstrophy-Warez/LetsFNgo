import type { PaintColor } from './types';

const SC21 = 'https://www.supercars.net/blog/ford-updates-the-mustang-and-shelby-gt500-for-2021-model-year';
const MA21 = 'https://mustangattitude.com/mustang/2021shelby.shtml';
const PARTIAL = 'Only the years listed are sourced; availability in other years is unconfirmed.';
const NOCODE = 'Paint code not found in sources (order guide not retrieved).';

/**
 * Colors seen in sources. The full per-year list with codes was NOT retrieved
 * (MustangAttitude pages blocked), so codes are null unless sourced.
 * Swatches are approximate display colors only.
 */
export const colors: PaintColor[] = [
  { id: 'grabber-lime', name: 'Grabber Lime', code: null, swatch: '#9ccc2a', years: [2020], source: SC21, confidence: 'reported', note: `Dropped for 2021. Dealer claims rarest 2020 color (376). ${NOCODE}` },
  { id: 'kona-blue', name: 'Kona Blue', code: null, swatch: '#1f3f8f', years: [2020], source: SC21, confidence: 'reported', note: `Dropped for 2021. ${NOCODE}` },
  { id: 'magnetic', name: 'Magnetic', code: null, swatch: '#55585c', years: [2020], source: SC21, confidence: 'reported', note: `Dropped for 2021. ${NOCODE}` },
  { id: 'wimbledon-white', name: 'Wimbledon White', code: null, swatch: '#f1efe6', years: [2020], source: SC21, confidence: 'reported', note: `Dropped as a body color for 2021; used for 2022 Heritage Edition stripes. ${NOCODE}` },
  { id: 'twister-orange', name: 'Twister Orange', code: null, swatch: '#e2601c', years: [2020], yearsNote: PARTIAL, source: 'https://mustangattitude.com/mustang/2020cars8.shtml', confidence: 'reported', note: NOCODE },
  { id: 'iconic-silver', name: 'Iconic Silver', code: null, swatch: '#b9bcbf', years: [2020, 2022], yearsNote: PARTIAL, source: 'https://www.ford-trucks.com/?p=119208', confidence: 'reported', note: `Seen on 2020 (Barrett-Jackson) and 2022 (PCARMarket) cars. ${NOCODE}` },
  { id: 'oxford-white', name: 'Oxford White', code: null, swatch: '#f7f7f4', years: [2021], yearsNote: PARTIAL, source: 'https://www.ford-trucks.com/?p=119208', confidence: 'reported', note: NOCODE },
  { id: 'antimatter-blue', name: 'Antimatter Blue Metallic', code: null, swatch: '#1b2433', years: [2021, 2022], yearsNote: 'Added for 2021; 2022 availability assumed from continuity, not sourced.', source: SC21, confidence: 'reported', note: NOCODE },
  { id: 'carbonized-gray', name: 'Carbonized Gray Metallic', code: 'M7 (M7458)', swatch: '#4a4d50', years: [2021], yearsNote: 'Added for 2021; later years not sourced.', source: MA21, confidence: 'confirmed' },
  { id: 'grabber-yellow', name: 'Grabber Yellow', code: null, swatch: '#f2c500', years: [2021], yearsNote: 'Added for 2021; later years not sourced.', source: SC21, confidence: 'reported', note: NOCODE },
  { id: 'dark-matter-gray', name: 'Dark Matter Gray', code: null, swatch: '#3a3d40', years: [2022], yearsNote: PARTIAL, source: 'https://www-backend.pcarmarket.com/auction/2022-ford-mustang-gt500-1', confidence: 'reported', note: NOCODE },
  { id: 'code-orange', name: 'Code Orange', code: null, swatch: '#ff6a13', years: [2022], source: 'https://www.carscoops.com/?p=2394782', confidence: 'reported', note: `Added for 2022. ${NOCODE}` },
  { id: 'brittany-blue', name: 'Brittany Blue', code: null, swatch: '#7fa7b8', years: [2022], source: 'https://www.thespeedjournal.com/limited-edition-2022-mustang-shelby-gt500-heritage-edition/', confidence: 'confirmed', note: `Heritage Edition only. ${NOCODE}` },
];
