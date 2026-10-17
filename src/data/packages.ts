import type { OptionPackage } from './types';

export const packages: OptionPackage[] = [
  {
    id: 'cftp', name: 'Carbon Fiber Track Pack (CFTP)', years: [2020, 2021, 2022], source: 'https://www.motor1.com/news/357225/2020-ford-mustang-shelby-gt500-price/', confidence: 'confirmed',
    price: { value: 18500, source: 'https://www.motor1.com/news/357225/2020-ford-mustang-shelby-gt500-price/', confidence: 'confirmed' },
    priceConflicts: [{ value: 18000, source: 'https://fordauthority.com/2020/09/2020-shelby-gt500-carbon-fiber-track-pack-explores-its-lofty-limits-video', confidence: 'reported', context: 'One source' },
      { value: 18900, source: 'https://www.thedrive.com/news/29420/2020-ford-mustang-shelby-gt500-weighs-223-pounds-less-than-challenger-hellcat-leak-claims', confidence: 'reported', context: 'Leaked 2020 order guide coverage' }],
    contents: ['20-in carbon fiber wheels on Michelin Pilot Sport Cup 2', 'GT4-derived carbon fiber rear wing (fixed vs. adjustable conflicts; Jalopnik says adjustable)', 'Splitter wickers', 'Carbon fiber instrument panel', 'Recaro seats', 'Rear-seat delete', 'Adjustable strut-top mounts', 'Wheel locks'],
    contentsConfidence: 'confirmed',
    note: '2022 availability supported by a 2022 Heritage CFTP sold on PCARMarket. 2021 dealer listings show $18,500; the $18,900 leaked-guide figure may reflect a model-year difference rather than an error.',
  },
  {
    id: 'cfhp', name: 'Carbon Fiber Handling Package', years: [2021], source: 'https://web.archive.org/web/20240529210008/https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', originalUrl: 'https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', confidence: 'reported',
    price: { value: 10000, source: 'https://web.archive.org/web/20240529210008/https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', originalUrl: 'https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', confidence: 'reported' },
    contents: ['20-in black-painted carbon fiber wheels', 'Adjustable strut-top mounts', 'Oil catch can', 'Gurney flap', 'Splitter wickers', 'Wheel locks'],
    contentsConfidence: 'reported',
    note: 'Dropped for 2022 (CarsDirect via Carscoops; Ford Authority, fordauthority.com/2021/11/2022-ford-mustang-shelby-gt500-drops-carbon-fiber-handling-package/).',
  },
  {
    id: 'handling', name: 'Handling Package', years: [2020, 2021, 2022], source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified',
    price: { value: 1500, source: 'https://www.musclecarsandtrucks.com/2021-ford-mustang-shelby-gt500-carbon-fiber-handling-package-costs-10000/', confidence: 'reported', context: '2020, USD' },
    priceConflicts: [
      { value: 1500, source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified', context: 'USD' },
      { value: 1750, source: 'https://www.pcarmarket.com/auction/2020-ford-mustang-shelby-gt500/', confidence: 'unverified', context: 'USD' },
      { value: 1895, source: 'https://www.mustang6g.com/forums/threads/2020-gt500-handling-package.130958/', confidence: 'unverified', context: 'CAD' },
    ],
    contents: ['Adjustable strut-top mounts (installed at plant)', 'Oil catch can', 'Gurney flap (ships loose)', 'Splitter wickers (ships loose)', 'Wheel lock kit (Ford Authority table only)'],
    contentsConfidence: 'reported',
    note: '2020 price and contents per musclecarsandtrucks.com and Ford Authority (fordauthority.com/2021/11/2022-ford-mustang-shelby-gt500-drops-carbon-fiber-handling-package/). Availability for 2021-2022 not confirmed per year.',
  },
  {
    id: 'tech', name: 'Technology Package', years: [2020, 2021, 2022], source: 'https://www.carvana.com/vehicle/4805574', confidence: 'reported',
    price: { value: 3000, source: 'https://www.carvana.com/vehicle/4805574', confidence: 'reported', note: 'Approximate.' },
    contents: ['Navigation', 'Blind-spot monitoring (BLIS) with cross-traffic alert', 'B&O 12-speaker audio', 'Heated mirrors'],
    contentsConfidence: 'reported',
    note: 'Year availability not confirmed per year. 2021 dealer listings show $3,000 (americanmusclecarz.com/vehicles/20512, stlouiscarmuseum.com/vehicles/1075).',
  },
  {
    id: 'heritage-pkg', name: 'Heritage Edition Package', years: [2022], source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed',
    price: { value: 2140, source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed', context: 'Vinyl stripes' },
    priceConflicts: [{ value: 12140, source: 'https://www.motorauthority.com/news/1134161_2022-ford-mustang-shelby-gt500-heritage-edition-gets-retro-look', confidence: 'confirmed', context: 'Hand-painted stripes (total)' },
      { value: 10000, source: 'https://www.mustangspecs.com/?p=52472', confidence: 'reported', context: 'Hand-painted stripes, added cost per mustangspecs' }],
    contents: ['Brittany Blue paint', 'Wimbledon White over-the-top stripes (vinyl or hand-painted)'],
    contentsConfidence: 'confirmed',
    note: 'Not a conflict: two stripe options. Carscoops labels the $2,140 option "painted", likely a wording error. The Shop Magazine also lists $2,140 vinyl / $12,140 painted (theshopmag.com).',
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
    id: 'recaro', name: 'Recaro seats', years: [2020], source: 'https://www.motor1.com/news/370086/most-expensive-mustang-shelby-gt500/', confidence: 'reported',
    price: { value: 1595, source: 'https://www.motor1.com/news/370086/most-expensive-mustang-shelby-gt500/', confidence: 'reported' },
    contents: [], contentsConfidence: 'reported',
    note: 'Also included in the Carbon Fiber Track Pack. 2021 and 2022 prices not found.',
  },
  {
    id: 'convenience', name: 'Convenience Package / Recaro seats / stripe options', years: [], source: 'https://mustangattitude.com/mustang/2022shelby.shtml', confidence: 'unverified',
    price: { value: null, source: 'https://mustangattitude.com/mustang/2022shelby.shtml', confidence: 'unverified', note: 'Not found — source blocked.' },
    contents: [], contentsConfidence: 'unverified',
    note: 'Convenience Package contents and 2021 Recaro/stripe option prices were not retrieved. Ford noted the ~$10k painted stripes were surprisingly popular.',
  },
];
