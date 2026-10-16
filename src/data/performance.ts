import type { PerformanceRecord } from './types';

const CD = 'https://fordauthority.com/2021/01/ford-mustang-shelby-gt500-is-quicker-without-the-carbon-fiber-track-pack';

export const performance: PerformanceRecord[] = [
  { id: 'ford-060', category: 'acceleration', label: 'Ford claim 0–60 mph', result: '3.3 s (prepped surface)', car: 'stock', date: '2019', source: 'https://www.musclecarsandtrucks.com/2020-ford-mustang-shelby-gt500-0-60-quarter-mile-times-revealed/', confidence: 'confirmed' },
  { id: 'ford-qm', category: 'quarter-mile', label: 'Ford claim ¼ mile', result: '10.7 s (prepped surface)', car: 'stock', date: '2019', source: 'https://www.musclecarsandtrucks.com/2020-ford-mustang-shelby-gt500-0-60-quarter-mile-times-revealed/', confidence: 'confirmed' },
  { id: 'cd-base', category: 'acceleration', label: 'Car and Driver, base car', result: '0–60 3.4 s · 0–100 6.9 s · ¼ 11.3 s', car: 'stock', date: '2021-01', source: CD, confidence: 'reported' },
  { id: 'cd-cftp', category: 'acceleration', label: 'Car and Driver, CFTP car', result: '0–60 3.4 s · 0–100 7.1 s · ¼ 11.4 s', car: 'stock (CFTP)', date: '2021-01', source: CD, confidence: 'reported', note: 'Slower than base; blamed on Cup 2 tires on an unprepped strip.' },
  { id: 'edmunds', category: 'quarter-mile', label: 'Edmunds three-way test', result: '11.3 s', car: 'stock (CFTP)', date: '2020', source: 'https://edmunds.com/ford/shelby-gt500/2020/review', confidence: 'reported' },
  { id: 'best-stock', category: 'quarter-mile', label: 'Best stock pass (private test, Bradenton)', result: '10.61 s @ 133 mph', car: 'stock', date: '2020', source: 'https://www.motor1.com/news/379132/2020-shelby-gt500-quarter-mile/', confidence: 'reported' },
  { id: 'customer-stock', category: 'quarter-mile', label: 'Customer car, Texas Motorplex', result: '10.66 s', car: 'stock', date: '2020', source: 'https://www.dragzine.com/?p=1864682', confidence: 'reported' },
  { id: 'lap-vir', category: 'lap', label: 'VIR Grand West (LapMeta, user-submitted)', result: '2:44.5', car: 'stock', date: null, source: 'https://www.lapmeta.com/en/vi/6210', confidence: 'unverified' },
  { id: 'lap-laguna', category: 'lap', label: 'Laguna Seca (LapMeta, user-submitted)', result: '1:33.8', car: 'stock', date: null, source: 'https://www.lapmeta.com/en/vi/6210', confidence: 'unverified' },
  { id: 'lap-th', category: 'lap', label: 'Throttle House lap test (worn tires)', result: '1:28.15 (ZL1 1LE 1:27.20)', car: 'stock', date: '2020', source: 'https://www.carscoops.com/?p=1967930', confidence: 'reported' },
  { id: 'rec-boltons', category: 'drag-record', label: 'Stock-pulley bolt-on cars', result: '9.7–9.9 s', car: 'modified', date: null, source: 'https://www.hotcars.com/stock-pulley-mustang-shelby-gt500-quarter-mile-record/', confidence: 'reported', note: 'SPE intake, Lethal race pipe, PBD tune, drag radials.' },
  { id: 'rec-970', category: 'drag-record', label: '2020 car, then-record', result: '9.70 s @ 144.57 mph', car: 'modified', date: '2020', source: 'https://themustangsource.com/?p=34398', confidence: 'reported' },
  { id: 'rec-lethal', category: 'drag-record', label: 'Lethal Performance, stock motor + Whipple 3.8L', result: '8.86 s @ 163 mph', car: 'modified', date: null, source: 'https://www.fordmuscle.com/?p=938086', confidence: 'reported' },
  { id: 'rec-pbd', category: 'drag-record', label: 'Palm Beach Dyno, stock engine & DCT', result: '8.80 s @ 158 mph', car: 'modified', date: null, source: 'https://www.youtube.com/watch?v=6F8hEli7IE4', confidence: 'reported', note: 'Blower spec in secondary summary is suspect; listed as unknown.' },
  { id: 'rec-codered', category: 'drag-record', label: 'Shelby GT500 Code Red', result: '8.59 s @ 161 mph', car: 'Shelby American', date: null, source: 'https://www.youtube.com/watch?v=ajsZ3rrLxjs', confidence: 'reported' },
];

export const performanceWarning = {
  text: 'A fake R&T test sheet circulated online; only attributable tests are listed. Records are dated snapshots — current (2024–26) records were not verified.',
  source: 'https://www.musclecarsandtrucks.com/theres-a-fake-2020-ford-mustang-gt500-test-sheet-on-the-internet/',
  confidence: 'confirmed' as const,
};
