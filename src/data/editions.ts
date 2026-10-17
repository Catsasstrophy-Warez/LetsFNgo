import type { ShelbyEdition } from './types';

/**
 * Shelby American editions on the 2020–22 GT500 (research round 8). Prices, caps and power are Shelby or press
 * claims as sourced. Unknowns stay null; topics searched with no source found are listed in `editionGaps`.
 */
const SE = 'https://shelby.com/Vehicles/GT500-Signature-Edition';
const KR_AUTOBLOG = 'https://www.autoblog.com/2021/12/16/ford-shelby-mustang-gt500kr-60th-anniversary/';
const KR_MOTOR1 = 'https://www.motor1.com/news/554870/mustang-shelby-gt500kr-2020-2022/';
const CR = 'https://shelby.com/multimedia/News/Press-Releases/shelby-american-turns-shelby-gt500-code-red-experimental-car-into-limited-production-edition-with-up-to-1300-horsepower-1';

export const editions: ShelbyEdition[] = [
  {
    id: 'gt500se', name: 'Shelby GT500 Signature Edition (GT500SE)', years: '2020-2022', modelYears: [2020, 2021, 2022],
    hpClaim: '800+ (93 octane)', price: 29995, priceNote: 'upgrade only, excludes car and shipping',
    production: '100 per model year',
    productionConflicts: [
      { value: '100 per model year', source: SE, confidence: 'confirmed' },
      { value: '98 per model year (North America)', source: 'https://www.shelby.com/multimedia/News/ArtMID/5059/ArticleID/76', confidence: 'unverified', note: 'One 2021 Shelby release, read from a search snippet (low).' },
    ],
    content: 'pulley, intercooler/heat exchanger, adjustable springs, sway bars, caster/camber plates, 20in wheels, dry carbon vented hood, stripes, leather recovers, numbered plates; widebody optional',
    streetLegal: null, source: SE, confidence: 'confirmed', research: 'high',
  },
  {
    id: 'gt500kr', name: 'Shelby GT500KR', years: '2022 (upfit available for 2020-2021 cars)', modelYears: [2020, 2021, 2022],
    hpClaim: '900+ (93 octane)', price: 127895, priceNote: 'new car, starting price', upfitPrice: 54995,
    production: '225 total incl. 45 overseas (split disputed)',
    productionConflicts: [
      { value: '225 total incl. 45 overseas', source: KR_AUTOBLOG, confidence: 'reported' },
      { value: '120 retrofits plus 60 new', source: KR_MOTOR1, confidence: 'unverified', note: 'The round-8 notes record this new-versus-upgrade split from search summaries of the cited KR sources without naming which one; Motor1 itself returned 502.' },
    ],
    content: null, streetLegal: null, source: KR_AUTOBLOG, confidence: 'reported', research: 'medium',
    note: 'Production was due to start in Q1 2022; the first production car was auctioned at Barrett-Jackson in January 2022.',
  },
  {
    id: 'code-red', name: 'Shelby GT500 Code Red', years: '2022 announcement; donors MY2020-2022', modelYears: [2020, 2021, 2022],
    hpClaim: '1000+ hp/780 lb-ft on 93; up to 1300 hp/1000 lb-ft on E85', price: 209995, priceNote: 'plus donor car',
    production: '30 (10 per MY)',
    content: 'twin turbo replaces supercharger, Manley pistons and rods, E85 fuel system, widebody; not street legal',
    streetLegal: false, source: CR, confidence: 'reported', research: 'medium',
    note: 'Not street legal per Top Gear; price per duPont Registry.',
  },
];

/** Searched for, nothing sourced. Shown as empty slots, never filled from memory. */
export const editionGaps = ['Shelby Super Snake on the 2020-22 GT500 platform'];
