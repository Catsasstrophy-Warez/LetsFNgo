import type { OptionPackage } from './types';

export const packages: OptionPackage[] = [
  {
    id: 'cftp', name: 'Carbon Fiber Track Pack (CFTP)', years: [2020, 2021, 2022], source: 'https://www.motor1.com/news/357225/2020-ford-mustang-shelby-gt500-price/', confidence: 'confirmed',
    price: { value: 18500, source: 'https://www.motor1.com/news/357225/2020-ford-mustang-shelby-gt500-price/', confidence: 'confirmed' },
    priceConflicts: [{ value: 18000, source: 'https://fordauthority.com/2020/09/2020-shelby-gt500-carbon-fiber-track-pack-explores-its-lofty-limits-video', confidence: 'reported', context: 'One source' }],
    contents: ['20-in carbon fiber wheels on Michelin Pilot Sport Cup 2', 'GT4-derived carbon fiber rear wing (fixed vs. adjustable conflicts; Jalopnik says adjustable)', 'Splitter wickers', 'Carbon fiber instrument panel', 'Recaro seats', 'Rear-seat delete', 'Adjustable strut-top mounts', 'Wheel locks'],
    contentsConfidence: 'confirmed',
    note: '2022 availability supported by a 2022 Heritage CFTP sold on PCARMarket.',
  },
  {
    id: 'cfhp', name: 'Carbon Fiber Handling Package', years: [2021], source: 'https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', confidence: 'reported',
    price: { value: 10000, source: 'https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', confidence: 'reported' },
    contents: ['20-in painted carbon fiber wheels', 'Adjustable strut-top mounts', 'Oil catch can', 'Wheel locks'],
    contentsConfidence: 'reported',
    note: 'Reportedly dropped for 2022 (CarsDirect via Carscoops).',
  },
  {
    id: 'handling', name: 'Handling Package', years: [2020, 2021, 2022], source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified',
    price: { value: null, source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified', note: 'Conflicting prices; see alternatives.' },
    priceConflicts: [
      { value: 1500, source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified', context: 'USD' },
      { value: 1750, source: 'https://www.pcarmarket.com/auction/2020-ford-mustang-shelby-gt500/', confidence: 'unverified', context: 'USD' },
      { value: 1895, source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified', context: 'CAD' },
    ],
    contents: ['Gurney flap (most reports)', 'Splitter wickers (most reports)'],
    contentsConfidence: 'unverified',
    note: 'Contents disputed; treat as unverified until an order guide is found. Year availability not confirmed.',
  },
  {
    id: 'tech', name: 'Technology Package', years: [2020, 2021, 2022], source: 'https://www.carvana.com/vehicle/4805574', confidence: 'reported',
    price: { value: 3000, source: 'https://www.carvana.com/vehicle/4805574', confidence: 'reported', note: 'Approximate.' },
    contents: ['Navigation', 'Blind-spot monitoring (BLIS)', 'B&O audio', 'Heated mirrors'],
    contentsConfidence: 'reported',
    note: 'Year availability not confirmed per year.',
  },
  {
    id: 'heritage-pkg', name: 'Heritage Edition Package', years: [2022], source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed',
    price: { value: 2140, source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed', context: 'Vinyl stripes' },
    priceConflicts: [{ value: 12140, source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed', context: 'Hand-painted stripes' }],
    contents: ['Brittany Blue paint', 'Wimbledon White over-the-top stripes (vinyl or hand-painted)'],
    contentsConfidence: 'confirmed',
    note: 'Not a conflict: two stripe options. Carscoops labels the $2,140 option "painted", likely a wording error.',
  },
  {
    id: 'extra-paint', name: 'Extra-cost paint (Twister Orange / Rapid Red)', years: [2020], source: 'https://fordauthority.com/2019/09/2020-ford-mustang-shelby-gt500-colors/', confidence: 'unverified',
    price: { value: null, source: 'https://fordauthority.com/2019/09/2020-ford-mustang-shelby-gt500-colors/', confidence: 'unverified', note: 'Snippet lists $495 and $395; which color carries which price is ambiguous.' },
    priceConflicts: [
      { value: 495, source: 'https://fordauthority.com/2019/09/2020-ford-mustang-shelby-gt500-colors/', confidence: 'unverified' },
      { value: 395, source: 'https://fordauthority.com/2019/09/2020-ford-mustang-shelby-gt500-colors/', confidence: 'unverified' },
    ],
    contents: [], contentsConfidence: 'reported',
  },
  {
    id: 'convenience', name: 'Convenience Package / Recaro seats / stripe options', years: [], source: 'https://mustangattitude.com/mustang/2022shelby.shtml', confidence: 'unverified',
    price: { value: null, source: 'https://mustangattitude.com/mustang/2022shelby.shtml', confidence: 'unverified', note: 'Not found — source blocked.' },
    contents: [], contentsConfidence: 'unverified',
    note: 'Convenience Package contents and Recaro/stripe option prices were not retrieved. Ford noted the ~$10k painted stripes were surprisingly popular.',
  },
];
