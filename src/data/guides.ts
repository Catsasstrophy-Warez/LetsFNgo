import type { Guide } from './types';
import { LMR, MC_DCT, SUPP21, SUPP_NOTE } from './maintenance';

const FORD_WARRANTY = 'https://www.ford.com/support/warranty/';

/**
 * How-to guides built only from facts already sourced in maintenance.ts (and round-6 notes). These are
 * checklists of what the sources say, not workshop procedures. Planned slots stay empty until a source exists.
 */
export const guides: Guide[] = [
  {
    id: 'track-service', title: 'Track-day maintenance (2021 supplement)', status: 'ready', appliesTo: '2021 GT500 (2020/2022 unconfirmed)',
    summary: 'What the 2021 GT500 owner-manual supplement says to do before and after track use.',
    source: SUPP21, confidence: 'reported', note: SUPP_NOTE, tools: [], partIds: ['wss-m6c65-a2', 'fl-2087', 'wss-m2c931-e1'],
    warnings: [{ text: 'Only the 2021 supplement was found; 2020 and 2022 cars may differ. Check your own owner\'s manual.', source: SUPP21, confidence: 'reported' }],
    steps: [
      { text: 'Before the event: replace the brake fluid with DOT 4 LV (dry boiling point above 500 °F), spec WSS-M6C65-A2.', source: SUPP21, confidence: 'reported', factId: 'track-intervals' },
      { text: 'After one track weekend or about 4 hours of track driving: change the engine oil (SAE 5W-50) and the oil filter (FL-2087).', source: SUPP21, confidence: 'reported', factId: 'track-intervals' },
      { text: 'Every 500 miles of track use, or whenever the axle over-temperature warning appears: change the rear axle fluid.', source: SUPP21, confidence: 'reported', factId: 'diff-fluid' },
      { text: 'Log each service in the Garage so the reminders reset.', source: SUPP21, confidence: 'reported' },
    ],
  },
  {
    id: 'dct-fluid', title: 'DCT fluid: what to use and when', status: 'ready', appliesTo: '2020–2022 GT500 (TR-9070)',
    summary: 'The correct dual-clutch fluid, the scheduled intervals and the sourced capacity.',
    source: MC_DCT, confidence: 'unverified', tools: [], partIds: ['xt-14-l', 'xt-11-qdc'],
    warnings: [{ text: 'XT-11-QDC (WSS-M2C200-D2) is a dry-clutch fluid and is NOT correct for the GT500 TR-9070.', source: MC_DCT, confidence: 'confirmed' }],
    steps: [
      { text: 'Use Motorcraft XT-14-L GT500 Dual Clutch Transmission Fluid. Motorcraft says it meets all powertrain warranty requirements.', source: MC_DCT, confidence: 'confirmed', factId: 'dct-fluid' },
      { text: 'Every 20,000 mi: replace the DCT side filter and top off the fluid.', source: SUPP21, confidence: 'reported', factId: 'supp-intervals' },
      { text: 'Every 40,000 mi: replace the DCT fluid and side filter.', source: SUPP21, confidence: 'reported', factId: 'supp-intervals' },
      { text: 'Capacity: 8.0 qt total. A drain-and-fill takes about 3–4 qt, according to owners. Neither figure is confirmed by Ford.', source: LMR, confidence: 'unverified', factId: 'dct-cap' },
    ],
  },
  {
    id: 'track-alignment', title: 'Track alignment (forum transcription)', status: 'ready', appliesTo: '2020 GT500 with the Carbon Fiber Track Pack',
    summary: 'Track alignment values from the CFTP supplement, as one forum user typed them out.',
    source: 'https://www.mustang6g.com/forums/threads/road-course-thoughts.137294/post-2822069', confidence: 'unverified', tools: [], partIds: [],
    warnings: [{ text: 'A forum user transcribed these values (round 6), and they have not been checked against the supplement. Have an alignment shop confirm them.', source: 'https://www.mustang6g.com/forums/threads/road-course-thoughts.137294/post-2822069', confidence: 'unverified' }],
    steps: [
      { text: 'Front: camber −2.25°, caster 8.08°, total toe −0.10 (out).', source: 'https://www.mustang6g.com/forums/threads/road-course-thoughts.137294/post-2822069', confidence: 'unverified' },
      { text: 'Rear: camber −2.20°, total toe 0.30 (in).', source: 'https://www.mustang6g.com/forums/threads/road-course-thoughts.137294/post-2822069', confidence: 'unverified' },
    ],
  },
  // Planned slots: wanted, but no source backs a procedure yet.
  {
    id: 'break-in', title: 'Break-in', status: 'planned', appliesTo: '2020–2022 GT500', summary: 'No 2020–2022 Ford break-in text has been found. The only sourced text comes from the 2014 GT500 supplement, a different car, so it is not shown here as guidance.',
    source: 'https://www.mustang6g.com/forums/threads/gt500-break-in-period.127991/', confidence: 'unverified', tools: [], partIds: [], warnings: [], steps: [],
  },
  { id: 'tire-pressures', title: 'Placard and track tire pressures', status: 'planned', appliesTo: '2020–2022 GT500', summary: 'No Ford-sourced placard or Cup 2 track pressures found yet (round 6).', source: FORD_WARRANTY, confidence: 'unverified', tools: [], partIds: [], warnings: [], steps: [] },
  { id: 'launch-control', title: 'Launch control and line lock', status: 'planned', appliesTo: '2020–2022 GT500', summary: 'No sourced procedure yet (round 6).', source: FORD_WARRANTY, confidence: 'unverified', tools: [], partIds: [], warnings: [], steps: [] },
  { id: 'oil-change', title: 'Oil and filter change procedure', status: 'planned', appliesTo: '2020–2022 GT500', summary: 'The fluids and filter are sourced (see Parts & Fluids), but a step-by-step procedure is not. Capacity sources conflict (10–11.5 qt).', source: LMR, confidence: 'unverified', tools: [], partIds: ['fl-2087', 'wss-m2c931-e1'], warnings: [], steps: [] },
];

const RANK = { confirmed: 2, reported: 1, unverified: 0 } as const;
/** The weakest confidence among a guide's steps (a guide is only as strong as its weakest step). */
export const weakestStep = (g: Guide) => g.steps.reduce((m, s) => (RANK[s.confidence] < RANK[m] ? s.confidence : m), 'confirmed' as Guide['confidence']);
