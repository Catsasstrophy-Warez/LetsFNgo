import type { Competitor } from './types';

const CD3 = 'https://fordauthority.com/2020/02/2020-shelby-gt500-vs-camaro-zl1-1le-vs-challenger-hellcat-redeye-at-the-drag-strip';

export const competitors: Competitor[] = [
  { id: 'gt500', name: 'Shelby GT500 (2020)', power: '760 hp / 625 lb-ft', quarterMile: '11.4 s @ 132 mph (C/D)', lap: '1:28.15 (Throttle House, worn tires)', price: '$94,665 as tested (C/D)', verdict: 'Quickest at the drag strip.', source: CD3, confidence: 'reported' },
  { id: 'zl1', name: 'Chevrolet Camaro ZL1 1LE', power: null, quarterMile: '11.5 s @ 124 mph (C/D)', lap: '1:27.20 (Throttle House)', price: '$73,995 as tested (C/D)', verdict: 'Matched or beat the GT500 on road courses for less money.', source: 'https://fordauthority.com/2020/01/2020-ford-mustang-shelby-gt500-v-2019-chevrolet-camaro-zl1-1le', confidence: 'reported', note: 'Power figure not gathered.' },
  { id: 'redeye', name: 'Dodge Challenger SRT Hellcat Redeye', power: '797 hp', quarterMile: '11.6 s @ 128 mph (C/D)', lap: '1:32.59 (Throttle House, Hellcat)', price: null, verdict: 'Most power, slowest of the three in tests.', source: 'https://de.motor1.com/news/393206/gt500-hellcat-camaro-drag-race/', confidence: 'reported' },
  { id: 'z06', name: 'Chevrolet Corvette Z06 (C8)', power: '670 hp / 460 lb-ft', quarterMile: '10.6 s', lap: '3 s quicker than GT500 Track Pack at Buttonwillow', price: null, verdict: 'Quicker on track.', source: 'https://www.corvsport.com/comparing-the-c8-z06-to-a-shelby-gt500/', confidence: 'reported' },
  { id: '911', name: 'Porsche 911 GT3 / Turbo S', power: null, quarterMile: null, lap: null, price: null, verdict: 'Specs not gathered.', source: 'https://www.thedrive.com/new-cars/30681/2020-ford-mustang-shelby-gt500-review-a-911-gt2-rs-clone-with-fewer-homicidal-tendencies', confidence: 'unverified' },
];
