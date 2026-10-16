import type { ProductionFact } from './types';

export const production: ProductionFact[] = [
  { id: 'plan-2020', label: 'Planned 2020 volume', scope: '2020', value: '~5,000', source: 'https://fordauthority.com/2019/07/2020-ford-mustang-shelby-gt500-limited-to-5000-units/', confidence: 'reported', note: 'From an internal Ford slide.' },
  { id: 'built-2020', label: '2020 built', scope: '2020', value: 5860, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'reported', note: 'Forum build tally (unofficial), matching a dealer claim. Conflicts with "one of 5,000" in a Barrett-Jackson listing, which looks unreliable.', conflicts: [
    { value: 5860, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'reported', context: 'Mustang6G build tally' },
    { value: 5860, source: 'https://legendarymotorcar.com/inventory/2020-shelby-gt500-2955.aspx', confidence: 'unverified', context: 'Dealer claim' },
    { value: 5000, source: 'https://barrett-jackson.com/Events/Event/Details/2020-FORD-SHELBY-GT500-244661', confidence: 'unverified', context: 'Barrett-Jackson "one of 5,000"' },
  ] },
  { id: 'forum-2020', label: '2020 built (forum estimate)', scope: '2020', value: '~5,800', source: 'https://www.mustang6g.com/forums/threads/2022-gt500-production-numbers.173266/', confidence: 'unverified' },
  { id: 'c20-fpb', label: '2020 Ford Performance Blue ("Fast Pitch Blue" in tally)', scope: '2020 color tally', value: 843, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'unverified', note: 'Forum tally, unofficial.' },
  { id: 'c20-black', label: '2020 Shadow Black', scope: '2020 color tally', value: 829, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'unverified', note: 'Forum tally, unofficial.' },
  { id: 'c20-rapid', label: '2020 Rapid Red', scope: '2020 color tally', value: 775, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'unverified', note: 'Forum tally, unofficial.' },
  { id: 'c20-oxford', label: '2020 Oxford White', scope: '2020 color tally', value: 737, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'unverified', note: 'Forum tally, unofficial.' },
  { id: 'c20-race', label: '2020 Race Red', scope: '2020 color tally', value: 298, source: 'https://www.mustang6g.com/forums/goto/post?id=3548209', confidence: 'unverified', note: 'Forum tally, unofficial.' },
  { id: 'lime-2020', label: '2020 Grabber Lime (rarest color)', scope: '2020 color tally', value: 376, source: 'https://legendarymotorcar.com/inventory/2020-shelby-gt500-2955.aspx', confidence: 'unverified', note: 'Dealer claim. Other 2020 colors are not in the retrieved tally.' },
  { id: 'total', label: 'Total 2020–2022', scope: '2020–2022', value: '~9,000', source: 'https://www.automotiveaddicts.com/89664/how-many-shelby-gt500-cars-were-manufactured-over-the-years', confidence: 'unverified', note: 'Secondary estimate, unclear method.' },
  { id: 'cftp-total', label: 'CFTP cars 2020–2022', scope: '2020–2022', value: '~1,000', source: 'https://www.automotiveaddicts.com/89664/how-many-shelby-gt500-cars-were-manufactured-over-the-years', confidence: 'unverified', note: 'Ford says it does not track builds by package.' },
  { id: 'y2021', label: '2021 built', scope: '2021', value: null, source: 'https://www.mustang6g.com/forums/threads/build-statistics-for-2020-2022-run.179732/latest', confidence: 'unverified', note: 'Unknown — build-statistics thread blocked during research.' },
  { id: 'y2022', label: '2022 built', scope: '2022', value: null, source: 'https://mustangattitude.com/mustang/2022shelby.shtml', confidence: 'unverified', note: 'Unknown — Data Explorer blocked during research.' },
  { id: 'heritage', label: 'Heritage Edition', scope: '2022', value: 'approx. 225–255 (unconfirmed)', source: 'https://www.mustangspecs.com/mustang-of-the-day-2022-ford-mustang-shelby-gt500-heritage-edition/', confidence: 'unverified', note: 'Conflict: ~225 (mustangspecs) vs ~255 (Barrett-Jackson listing).' },
  { id: 'heritage-bj', label: 'Heritage Edition (Barrett-Jackson)', scope: '2022', value: '~255', source: 'https://barrett-jackson.com/Events/Event/Details/2022-FORD-SHELBY-GT500-HERITAGE-EDITION-266929', confidence: 'unverified' },
  { id: 'kr', label: 'Shelby GT500KR (limit)', scope: 'Shelby American', value: 180, source: 'https://en.wikipedia.org/wiki/Shelby_Mustang', confidence: 'reported' },
  { id: 'colors', label: 'Color / package splits', scope: '2020–2022', value: null, source: 'https://www.aol.com/ford-mustang-shelby-gt500s-10-214500277.html', confidence: 'unverified', note: 'Ford does not publish them.' },
];
