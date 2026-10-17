import type { AuctionResult, MarketStat } from './types';

/**
 * Auction and marketplace results (research round 7). Only what a source shows is recorded: venue, CFTP and
 * Heritage status are null when the source does not state them, and prices are null rather than converted.
 */
const DI = 'https://driveindex.com/cars/ford/mustang-shelby-gt500/2020';
const CV_BAT = 'https://www.theclassicvaluer.com/vehicle-details/bring-a-trailer-2026-07-25-ford-mustang-sixth-generation-gt500-0f5d54';
const CV_MECUM = 'https://www.theclassicvaluer.com/vehicle-details/mecum-2025-12-05-ford-mustang-sixth-generation-gt500-9efa60';
const MECUM_INDY = 'https://www.classic.com/a/mecum-indy-2026-Y4rALMp/lots/2022-ford-shelby-mustang-gt500kr-47BVMBp';
const MECUM_NOTE = 'Round 14: Classic.com "unofficial results" seen in a search summary (page returned 403).';
const KR_OUTLIER = 'Shelby American GT500KR, not a stock GT500; excluded from medians by default.';
const DI_NOTE = 'DriveIndex shows 15 of 78 sales for 2020 cars; venue, CFTP status and listing URL are not given per sale.';

const driveIndex2020: [string, number, number][] = [
  ['2026-10-07', 110000, 776], ['2026-09-05', 94000, 4400], ['2026-08-22', 84500, 1700], ['2026-08-17', 114000, 2800],
  ['2026-07-22', 112000, 2000], ['2026-07-14', 90500, 2300], ['2026-06-18', 80000, 13000], ['2026-06-11', 83500, 10000],
  ['2026-04-20', 97000, 1900], ['2026-04-13', 104000, 3800], ['2026-03-06', 87500, 1600], ['2026-02-12', 77500, 2800],
  ['2026-02-01', 96000, 479], ['2026-01-12', 101000, 215], ['2025-12-30', 78501, 4200],
];

/** Round 14: The Classic Valuer GBP conversions of the same BaT sales DriveIndex lists (low; not back-converted). */
const CV = 'https://www.theclassicvaluer.com/vehicle-details/bring-a-trailer-';
const batGbp: Record<string, Partial<AuctionResult>> = {
  '2026-06-11': { venue: 'Bring a Trailer', localPrice: { amount: 65142, currency: 'GBP' }, note: `${DI_NOTE} Round 14 (low): Bring a Trailer sale, The Classic Valuer shows £65,142 (${CV}2026-06-11-ford-mustang-sixth-generation-gt500-bab287). Listing: https://bringatrailer.com/listing/2020-ford-mustang-shelby-gt500-122/` },
  '2026-07-14': { venue: 'Bring a Trailer', localPrice: { amount: 71744, currency: 'GBP' }, note: `${DI_NOTE} Round 14 (low): Bring a Trailer sale, The Classic Valuer shows £71,744 (${CV}2026-07-14-ford-mustang-sixth-generation-gt500-948e1a). Listing: https://bringatrailer.com/listing/2020-ford-mustang-shelby-gt500-123/` },
  '2026-08-17': {
    venue: 'Bring a Trailer', note: `${DI_NOTE} Round 14 (low): Bring a Trailer sale. Listing: https://bringatrailer.com/listing/2020-ford-mustang-shelby-gt500-130/`,
    conflicts: [
      { value: '$114,000', source: DI, confidence: 'reported', context: 'DriveIndex' },
      { value: '£88,817', source: `${CV}2026-08-17-ford-mustang-sixth-generation-gt500-4b6b47`, confidence: 'unverified', context: 'The Classic Valuer page header (its own summary says $114,000)' },
    ],
  },
};

export const auctionResults: AuctionResult[] = [
  ...driveIndex2020.map(([date, price, mileage]): AuctionResult => ({
    id: `di-${date}-${mileage}`, date, venue: null, year: 2020, mileage, price, outcome: 'sold', cftp: null, heritage: null,
    description: '2020 GT500 sale listed by DriveIndex', source: DI, confidence: 'reported', note: DI_NOTE,
    ...batGbp[date],
  })),
  {
    id: 'mecum-indy-2026-kr-2022', date: '2026-05-16', venue: 'Mecum Indy', year: 2022, mileage: 1000, price: 187000, outcome: 'sold', cftp: null, heritage: null, outlier: KR_OUTLIER,
    description: '2022 Shelby GT500KR (about 1,000 mi)', source: MECUM_INDY, confidence: 'unverified', note: MECUM_NOTE,
  },
  {
    id: 'mecum-indy-2026-kr-2021', date: '2026-05-16', venue: 'Mecum Indy', year: 2021, mileage: null, price: 154000, outcome: 'sold', cftp: null, heritage: null, outlier: KR_OUTLIER,
    description: '2021 Shelby GT500KR (mileage not given)', source: MECUM_INDY, confidence: 'unverified', note: MECUM_NOTE,
  },
  {
    id: 'bat-2025-09-edsel', date: '2025-09-16', venue: 'Bring a Trailer', year: 2020, mileage: 666, price: 189901, outcome: 'sold', cftp: null, heritage: null,
    outlier: 'Celebrity provenance (Edsel Ford II owned); excluded from medians by default.',
    description: "Edsel Ford II's 2020 GT500 (auction record per the source)",
    source: 'https://fordauthority.com/2025/09/edsel-ford-iis-2020-ford-mustang-shelby-gt500-sets-new-auction-record/', confidence: 'reported',
    note: 'Figures first came from a search snippet (403); round 14 confirms the Sept 16, 2025 close at $189,901, 666 mi, Rapid Red — called the highest Shelby price on BaT.',
  },
  {
    id: 'bat-2026-07-25', date: '2026-07-25', venue: 'Bring a Trailer', year: 2021, mileage: 2500, price: null, localPrice: { amount: 91166, currency: 'GBP' }, outcome: 'sold', cftp: true, heritage: null,
    description: '2021 GT500 CFTP, Ford Performance Blue', source: CV_BAT, confidence: 'reported',
    note: 'Only a GBP conversion (£91,166) was found; the USD hammer price was not seen and is not back-converted. Listing: https://bringatrailer.com/listing/2021-ford-mustang-shelby-gt500-127/',
  },
  {
    id: 'mecum-2025-12-05', date: '2025-12-05', venue: 'Mecum', year: 2020, mileage: null, price: null, outcome: 'sold', cftp: null, heritage: null,
    description: '2020 GT500 — sources disagree on price and mileage', source: CV_MECUM, confidence: 'unverified',
    conflicts: [
      { value: '$88,000 · 1,900 mi', source: DI, confidence: 'unverified', context: 'DriveIndex' },
      { value: '£61,620 · 7,398 mi', source: CV_MECUM, confidence: 'unverified', context: 'The Classic Valuer (GBP conversion)' },
    ],
  },
  {
    id: 'bj-scottsdale-2025-1162', date: '2025-01', venue: 'Barrett-Jackson Scottsdale', year: 2020, mileage: 2553, price: null, outcome: 'sold', cftp: null, heritage: null,
    description: 'Lot 1162, 2020 GT500 (sold; price not shown)', source: 'https://www.barrett-jackson.com/scottsdale-2025/docket/vehicle/2020-ford-mustang-shelby-gt500-281241', confidence: 'reported',
  },
  {
    id: 'pcar-offer-100mi', date: null, venue: 'PCARMarket', year: 2020, mileage: 100, price: 85000, outcome: 'offer', cftp: null, heritage: null,
    description: '100-mile 2020 GT500, final offer (not a sale)', source: 'https://www.pcarmarket.com/', confidence: 'unverified',
    note: 'Research round 7 recorded the final offer but no listing URL or date; the link is the marketplace home page. Not a completed sale, so it is never charted as one.',
  },
];

/** Published medians / valuations. DriveIndex and ConceptCarz disagree; both are shown. */
export const marketStats: MarketStat[] = [
  { id: 'di-median-2024', label: 'DriveIndex median (sales in 2024)', year: 2020, kind: 'yearly-median', period: '2024', value: 86500, sampleSize: 11, source: DI, confidence: 'reported' },
  { id: 'di-median-2025', label: 'DriveIndex median (sales in 2025)', year: 2020, kind: 'yearly-median', period: '2025', value: 88000, sampleSize: 13, source: DI, confidence: 'reported' },
  { id: 'di-median-2026', label: 'DriveIndex median (sales in 2026)', year: 2020, kind: 'yearly-median', period: '2026', value: 95000, sampleSize: 14, source: DI, confidence: 'reported' },
  { id: 'di-median-all', label: 'DriveIndex headline median', year: 2020, kind: 'median', value: 90500, sampleSize: null, source: DI, confidence: 'reported' },
  {
    id: 'di-current', label: 'DriveIndex "current value" estimate', year: 2020, kind: 'estimate', value: 106367, source: DI, confidence: 'reported',
    conflicts: [{ value: 116875, source: 'https://www.conceptcarz.com/', confidence: 'unverified', context: 'ConceptCarz 2025 median from 4 sales (round 7; no page URL recorded, link is the site home)' }],
  },
];
