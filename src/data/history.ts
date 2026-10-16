import type { HistoryEvent, Milestone } from './types';

/** Owner events and programs (research round 8). Unknown dates and years stay null. */
export const events: HistoryEvent[] = [
  { id: 'track-attack', kind: 'program', name: 'Ford Performance Racing School GT500 Track Attack', date: null, location: 'Charlotte Motor Speedway', cost: 'free to owners (travel/hotel at owner expense)', source: 'https://jalopnik.com/ford-offers-free-program-to-teach-you-how-to-drive-your-1840391534', confidence: 'reported', research: 'medium', note: 'Years active and end date are not sourced. First owner program at the school’s Charlotte location after the move from Utah Motorsports Campus.' },
  { id: 'saac-46', kind: 'convention', name: 'SAAC-46', date: '2021', location: 'Sonoma Raceway', source: 'https://www.supercars.net/blog/saac-46-shelby-cars-converge-on-sears-point/', confidence: 'reported', research: 'medium' },
  { id: 'saac-47', kind: 'convention', name: 'SAAC-47', date: '2022', dateText: '2022 (early June, approx.)', location: 'Indianapolis Motor Speedway', source: 'https://thegentlemanracer.com/2022/06/shelby-american-automobile-club-at-indy/', confidence: 'reported', research: 'medium' },
  { id: 'saac-48', kind: 'convention', name: 'SAAC-48', date: '2023', location: 'Pittsburgh Vintage Grand Prix', source: 'https://www.supercars.net/blog/shelby-convention-to-be-held-at-pittsburgh-vintage-grand-prix/', confidence: 'reported', research: 'medium' },
  { id: 'kr-auction', kind: 'auction', name: 'First production GT500KR charity auction', date: '2022-01', dateText: '2022-01 (Barrett-Jackson Scottsdale)', location: 'Scottsdale, AZ', source: 'https://fordauthority.com/2022/01/first-production-2022-ford-shelby-gt500kr-heading-to-auction', confidence: 'reported', research: 'medium' },
];

/** Press and media milestones. */
export const milestones: Milestone[] = [
  { id: 'reveal', date: '2019-01-14', title: 'Public reveal at NAIAS Detroit (Cobo Center)', source: 'https://www.bloomberg.com/news/articles/2019-01-14/ford-debuts-most-powerful-mustang-ever-2020-ford-shelby-gt500', confidence: 'confirmed', research: 'high' },
  { id: 'rt-pcoty', date: '2020-12', title: 'Road & Track 2021 Performance Car of the Year', source: 'https://tremec.com/ford-mustang-shelby-gt500-awarded-2021-performance-car-of-the-year-by-road-track/', confidence: 'confirmed', research: 'high' },
  { id: 'mt-bdc-2020', date: '2020', title: "MotorTrend Best Driver's Car 2020 contender (CFTP); reportedly best Laguna Seca lap; final placement unknown", placement: null, source: 'https://themustangsource.com/?p=37078', confidence: 'unverified', research: 'low', note: 'Secondary source (low-medium).' },
];

/** Searched for, nothing sourced. */
export const historyGaps = ['Car and Driver 10Best', "MotorTrend Best Driver's Car 2020 final placement", 'GT500 Track Attack years active', 'Ford Media Center release dates'];
