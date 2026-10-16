import type { Competitor, CompetitorSheet } from './types';

const CD3 = 'https://fordauthority.com/2020/02/2020-shelby-gt500-vs-camaro-zl1-1le-vs-challenger-hellcat-redeye-at-the-drag-strip';

/** Round-2 spec-sheet numbers were written from memory by the researcher — every one is 'unverified'. */
const sheet = (hp: number, torque: number, weightLb: number, zeroTo60: number, quarterMile: number, priceUsd: number, source: string): CompetitorSheet =>
  ({ hp, torque, weightLb, zeroTo60, quarterMile, priceUsd, source, confidence: 'unverified', note: 'Written from memory in round-2 notes; not checked against the source.' });

const WC = 'https://en.wikipedia.org/wiki/Dodge_Challenger';
const WV = 'https://en.wikipedia.org/wiki/Chevrolet_Corvette_(C8)';
const WP = 'https://en.wikipedia.org/wiki/Porsche_911_(992)';

export const SHEET_CAVEAT = 'Spec-sheet rows (hp, torque, weight, 0–60, ¼ mile, price) came from round-2 notes written from memory and are unverified. Tested results above them come from cited comparison tests.';

export const competitors: Competitor[] = [
  { id: 'gt500', name: 'Shelby GT500 (2020)', power: '760 hp / 625 lb-ft', quarterMile: '11.4 s @ 132 mph (C/D)', lap: '1:28.15 (Throttle House, worn tires)', price: '$94,665 as tested (C/D)', verdict: 'Quickest at the drag strip.', source: CD3, confidence: 'reported',
    sheet: sheet(760, 625, 4170, 3.3, 10.7, 72900, 'https://en.wikipedia.org/wiki/Ford_Mustang_(sixth_generation)') },
  { id: 'zl1', name: 'Chevrolet Camaro ZL1 1LE', power: null, quarterMile: '11.5 s @ 124 mph (C/D)', lap: '1:27.20 (Throttle House)', price: '$73,995 as tested (C/D)', verdict: 'Matched or beat the GT500 on road courses for less money.', source: 'https://fordauthority.com/2020/01/2020-ford-mustang-shelby-gt500-v-2019-chevrolet-camaro-zl1-1le', confidence: 'reported',
    sheet: sheet(650, 650, 3900, 3.5, 11.4, 71500, 'https://en.wikipedia.org/wiki/Chevrolet_Camaro_(sixth_generation)') },
  { id: 'hellcat', name: 'Dodge Challenger SRT Hellcat', power: null, quarterMile: null, lap: '1:32.59 (Throttle House)', price: null, verdict: 'Lap time from the Throttle House test.', source: 'https://www.carscoops.com/?p=1967930', confidence: 'reported',
    sheet: sheet(717, 656, 4450, 3.6, 11.2, 60000, WC) },
  { id: 'redeye', name: 'Dodge Challenger SRT Hellcat Redeye', power: '797 hp', quarterMile: '11.6 s @ 128 mph (C/D)', lap: null, price: null, verdict: 'Most power of the C/D trio, slowest in the test.', source: 'https://de.motor1.com/news/393206/gt500-hellcat-camaro-drag-race/', confidence: 'reported',
    sheet: sheet(797, 707, 4450, 3.4, 10.8, 73000, WC) },
  { id: 'jailbreak', name: 'Dodge Challenger SRT Hellcat Redeye Jailbreak', power: null, quarterMile: null, lap: null, price: null, verdict: 'No tested comparison found.', source: WC, confidence: 'unverified',
    sheet: sheet(807, 707, 4450, 3.4, 10.8, 78000, WC) },
  { id: 'superstock', name: 'Dodge Challenger SRT Super Stock', power: null, quarterMile: null, lap: null, price: null, verdict: 'No tested comparison found.', source: WC, confidence: 'unverified',
    sheet: sheet(807, 707, 4400, 3.25, 10.5, 83000, WC) },
  { id: 'z51', name: 'Chevrolet Corvette Stingray Z51 (C8)', power: null, quarterMile: null, lap: null, price: null, verdict: 'Compared in Throttle House and MotorTrend videos (see Media).', source: 'https://www.youtube.com/watch?v=-gZLTLmZBGM', confidence: 'reported',
    sheet: sheet(495, 470, 3650, 2.9, 11.2, 65000, WV) },
  { id: 'z06', name: 'Chevrolet Corvette Z06 (C8)', power: '670 hp / 460 lb-ft', quarterMile: '10.6 s', lap: '3 s quicker than GT500 Track Pack at Buttonwillow', price: null, verdict: 'Quicker on track.', source: 'https://www.corvsport.com/comparing-the-c8-z06-to-a-shelby-gt500/', confidence: 'reported',
    sheet: sheet(670, 460, 3450, 2.6, 10.5, 106000, WV) },
  { id: '911s', name: 'Porsche 911 Carrera S (992)', power: null, quarterMile: null, lap: null, price: null, verdict: 'No tested comparison found.', source: WP, confidence: 'unverified',
    sheet: sheet(443, 390, 3380, 3.3, 11.2, 114000, WP) },
  { id: 'gt3', name: 'Porsche 911 GT3 (992)', power: null, quarterMile: null, lap: null, price: null, verdict: 'No tested comparison found.', source: WP, confidence: 'unverified',
    sheet: sheet(502, 346, 3160, 3.2, 11.0, 162000, WP) },
];
