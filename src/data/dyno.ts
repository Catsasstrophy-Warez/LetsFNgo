import type { DynoBaseline } from './types';

export const DYNO_CAVEAT = 'Stock results range from about 664 to 723 whp because the dyno type, correction standard, gear, fuel and weather differ between sources — none of these stock pulls clearly names a Dynojet. Compare your own pulls with a baseline from the same dyno.';

/** Sourced STOCK 2020–22 GT500 wheel figures (round 5). Each keeps its own source and confidence. */
export const dynoBaselines: DynoBaseline[] = [
  { id: 'lmr', label: 'LMR stock 2020 GT500', year: 2020, whp: 668, wtq: 560, dyno: 'other', correction: 'unknown', fuel: null, date: null, context: '668 whp @ 7,160 rpm, 560 lb-ft @ 4,130 rpm, 4th gear', source: 'https://lmr.com/products/how-much-power-does-a-stock-2020-gt500-make', confidence: 'reported', note: 'Dyno brand not stated; from a search snippet (page returned 403).' },
  { id: 'evolution', label: 'Evolution Performance stock baseline', year: 2020, whp: 684, wtq: 591, dyno: 'other', correction: 'unknown', fuel: null, date: null, source: 'https://www.nmradigital.com/the-story-behind-the-first-9-second-20-gt500/', confidence: 'reported', note: 'Same-dyno baseline for the Lund "Villain" build.' },
  { id: 'hennessey', label: 'Hennessey in-house dyno', year: 2020, whp: 708, wtq: null, dyno: 'other', correction: 'unknown', fuel: null, date: null, context: '≈ 7,300 rpm', source: 'https://ca.news.yahoo.com/2020-ford-mustang-shelby-gt500-201200865.html', note: 'Source link dead as of 2026-10-16.', confidence: 'reported' },
  { id: 'barrett', label: 'Barrett-Jackson lot description', year: 2020, whp: 664, wtq: null, dyno: 'other', correction: 'unknown', fuel: null, date: null, source: 'https://barrett-jackson.com/Events/Event/Details/2020-FORD-SHELBY-GT500-252024', confidence: 'unverified', note: 'Seller claim.' },
  { id: 'enginelabs', label: 'Whipple build baseline (EngineLabs)', year: 2020, whp: 723, wtq: null, dyno: 'other', correction: 'unknown', fuel: null, date: null, source: 'https://www.enginelabs.com/?p=299250', confidence: 'reported', note: 'Highest stock figure found — an outlier. Source link dead as of 2026-10-16.' },
];
