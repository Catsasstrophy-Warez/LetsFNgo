import type { ModelYearEntry } from './types';

const WIKI = 'https://en.wikipedia.org/wiki/Shelby_Mustang';

export const modelYears: ModelYearEntry[] = [
  {
    id: 'my2020', year: 2020, name: '2020 Shelby GT500', builder: 'Ford', source: 'https://jalopnik.com/the-2020-ford-mustang-shelby-gt500-will-start-at-70-30-1835940835', confidence: 'confirmed',
    summary: 'Launch year. Unveiled at the January 2019 Detroit auto show; built at Flat Rock, MI. Sold in North America and the Middle East, not Europe.',
    changes: ['Launch: $70,300 base + $1,095 destination + $2,600 gas guzzler tax = $73,995', 'Carbon Fiber Track Pack, Handling Package and Technology Package offered', 'Free GT500 Track Attack school for buyers'],
  },
  {
    id: 'my2021', year: 2021, name: '2021 Shelby GT500', builder: 'Ford', source: 'https://www.supercars.net/blog/ford-updates-the-mustang-and-shelby-gt500-for-2021-model-year', confidence: 'reported',
    summary: 'Mechanically unchanged. Palette refresh and a new $10,000 Carbon Fiber Handling Package.',
    changes: ['Added Antimatter Blue, Carbonized Gray (M7) and Grabber Yellow', 'Dropped Grabber Lime, Kona Blue, Magnetic and Wimbledon White', 'New Carbon Fiber Handling Package ($10,000)', 'No sourced 2021 base MSRP'],
  },
  {
    id: 'my2022', year: 2022, name: '2022 Shelby GT500', builder: 'Ford', source: 'https://www.carscoops.com/?p=2394782', confidence: 'reported',
    summary: 'Final year. Added Code Orange; Heritage Edition introduced. Base reported as $72,900 or $73,465 depending on how it is counted.',
    changes: ['Added Code Orange', 'Heritage Edition (see below)', 'Carbon Fiber Handling Package reportedly dropped (CarsDirect via Carscoops)'],
    note: 'A dealer listing claims the CFTP was dropped instead, but a 2022 Heritage Edition with CFTP sold on PCARMarket, so the Carscoops account is more credible.',
  },
  {
    id: 'heritage', year: 2022, name: '2022 Heritage Edition', builder: 'Ford', source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed',
    summary: 'Marks the 1967 GT500\'s 55th anniversary: Brittany Blue with Wimbledon White stripes, no mechanical changes. Dealer orders opened Nov 15, 2021.',
    changes: ['$2,140 with vinyl stripes', '$12,140 with hand-painted stripes', 'Production approx. 225–255 (unconfirmed)'],
  },
  {
    id: 'signature', year: null, name: 'Shelby American Signature Edition', builder: 'Shelby American', source: WIKI, confidence: 'reported',
    summary: 'Shelby American upgrade adding about 40 hp over the stock GT500.', changes: ['Full specs and pricing not found'],
  },
  {
    id: 'kr', year: null, name: 'Shelby GT500KR', builder: 'Shelby American', source: WIKI, confidence: 'reported',
    summary: 'Revealed December 15, 2021 for Shelby\'s 60th anniversary; limited to 180 units.', changes: ['Full specs and pricing not found'],
  },
  {
    id: 'code-red', year: null, name: 'Shelby GT500 Code Red', builder: 'Shelby American', source: WIKI, confidence: 'reported',
    summary: 'Twin-turbo 5.2L: over 1,000 hp on 93 octane, up to 1,300 hp on E85. About 10 cars a year planned. A Shelby American model, not a Ford one.',
    changes: ['Shelby video shows 8.59 s @ 161 mph quarter mile', 'Pricing not found'],
  },
];
