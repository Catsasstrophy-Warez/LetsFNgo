import type { HistoryEvent, Milestone } from './types';

/** Owner events and programs (research round 8). Unknown dates and years stay null. */
export const events: HistoryEvent[] = [
  { id: 'track-attack', kind: 'program', name: 'Ford Performance Racing School GT500 Track Attack', date: null, location: 'Charlotte Motor Speedway', cost: 'free to owners (travel/hotel at owner expense)', source: 'https://jalopnik.com/ford-offers-free-program-to-teach-you-how-to-drive-your-1840391534', confidence: 'reported', research: 'medium', note: 'Ran 2020 to November 2023 (see the end entry). First owner program at the school’s Charlotte location after the move from Utah Motorsports Campus.' },
  { id: 'track-attack-end', kind: 'program', name: 'GT500 Track Attack ended November 2023; replaced by Dark Horse Track Attack', date: '2023-11', dateText: 'ran 2020 to November 2023 (Dark Horse Track Attack registration opened January 2024)', location: 'Charlotte Motor Speedway', source: 'https://fordauthority.com/2023/11/ford-mustang-shelby-gt500-track-attack-program-ends/', confidence: 'reported', research: 'medium', note: 'Round 14: dates come from a search summary of the Ford Authority article (page returned 403). Earlier report (round 9): https://fordauthority.com/2024/01/ford-mustang-dark-horse-track-attack-registration-now-open' },
  { id: 'saac-46', kind: 'convention', name: 'SAAC-46', date: '2021', location: 'Sonoma Raceway', source: 'https://www.supercars.net/blog/saac-46-shelby-cars-converge-on-sears-point/', confidence: 'reported', research: 'medium' },
  { id: 'saac-47', kind: 'convention', name: 'SAAC-47', date: '2022', dateText: '2022 (early June, approx.)', location: 'Indianapolis Motor Speedway', source: 'https://thegentlemanracer.com/2022/06/shelby-american-automobile-club-at-indy/', confidence: 'reported', research: 'medium' },
  { id: 'saac-48', kind: 'convention', name: 'SAAC-48', date: '2023', location: 'Pittsburgh Vintage Grand Prix', source: 'https://www.supercars.net/blog/shelby-convention-to-be-held-at-pittsburgh-vintage-grand-prix/', confidence: 'reported', research: 'medium' },
  { id: 'kr-auction', kind: 'auction', name: 'First production GT500KR charity auction', date: '2022-01', dateText: '2022-01 (Barrett-Jackson Scottsdale)', location: 'Scottsdale, AZ', source: 'https://fordauthority.com/2022/01/first-production-2022-ford-shelby-gt500kr-heading-to-auction', confidence: 'reported', research: 'medium' },
];

/** Press and media milestones. */
export const milestones: Milestone[] = [
  { id: 'reveal', date: '2019-01-14', title: 'Public reveal at NAIAS Detroit (Cobo Center)', source: 'https://www.bloomberg.com/news/articles/2019-01-14/ford-debuts-most-powerful-mustang-ever-2020-ford-shelby-gt500', confidence: 'confirmed', research: 'high' },
  { id: 'rt-pcoty', date: '2020-12', title: 'Road & Track 2021 Performance Car of the Year', source: 'https://tremec.com/ford-mustang-shelby-gt500-awarded-2021-performance-car-of-the-year-by-road-track/', confidence: 'confirmed', research: 'high' },
  { id: 'mt-bdc-2020', date: '2020', title: "MotorTrend Best Driver's Car 2020 contender (CFTP); reportedly best Laguna Seca lap; final placement unknown", placement: null, source: 'https://themustangsource.com/?p=37078', confidence: 'unverified', research: 'low', note: 'Secondary source (low-medium). MotorTrend published no full ranking, so the GT500’s placement stays unknown.' },
  { id: 'mt-bdc-2020-winner', date: '2020', title: "MotorTrend Best Driver's Car 2020 won by the Porsche 718 Cayman GT4 (GT500 did not win)", placement: null, source: 'https://www.rennlist.com/how-tos/slideshows/porsche-718-cayman-gt4-pros-and-cons-623189', confidence: 'reported', research: 'medium', note: 'Field: Corvette C8 Z51, Ferrari F8 Tributo, Shelby GT500, Lamborghini Huracán Evo, 911 Turbo S, Cayenne Turbo Coupe, 718 Cayman GT4. GT500 placement not published.' },
];

/** Searched for, nothing sourced. */
export const historyGaps = ['Car and Driver 10Best', "MotorTrend Best Driver's Car 2020 final placement", 'Ford Media Center release dates'];
