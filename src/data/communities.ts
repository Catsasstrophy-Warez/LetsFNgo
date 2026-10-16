import type { Community } from './types';

export const communities: Community[] = [
  { id: 'm6g', name: 'Mustang6G', description: 'Most active hub for 2020+ GT500 and DCT threads (GT500 subforum URL not confirmed).', source: 'https://www.mustang6g.com/forums/threads/dct-performance.128063/', confidence: 'confirmed' },
  { id: 'tmo', name: 'Track Mustangs Online', description: 'Track-focused Mustang forum covering the GT500.', source: 'https://trackmustangsonline.com/threads/2020-gt500-kylo.15994/', confidence: 'confirmed' },
  { id: 'shelby-forums', name: 'Shelby American forums', description: 'Shelby owners forum (much content on older GT500s).', source: 'https://forums.shelby.com/', confidence: 'confirmed' },
  { id: 'reddit', name: 'r/GT500', description: 'Exists, but skews toward 2007–14 cars.', source: 'https://reddit.sudovanilla.org/r/GT500', note: 'Source link dead as of 2026-10-16.', confidence: 'reported' },
  { id: 'track-attack', name: 'GT500 Track Attack', description: 'Free one-day Ford Performance Racing School program for 2020 GT500 buyers at Charlotte Motor Speedway and zMAX Dragway (owners pay travel): classroom, the CMS road course and the four-wide zMAX drag strip (launch control, drive modes) in school-supplied GT500s. Optional paid second day in Mustang GTs with Ford Performance suspension and brakes. Whether it still ran for 2021–22 buyers is unconfirmed.', source: 'https://fordauthority.com/2019/12/gt500-track-attack-is-free-to-all-2020-gt500-buyers/', confidence: 'confirmed' },
  { id: 'tremec-shootout', name: 'TREMEC GT500 Shootout', description: 'Recurring owner drag event for these cars.', source: 'https://tremec-blog.com/?p=2264', confidence: 'reported' },
  { id: 'svtp', name: 'SVTPerformance', description: 'Forum root; GT500 subforum URL not verified.', source: 'https://www.svtperformance.com/', confidence: 'unverified' },
  { id: 'saac', name: 'Shelby American Automobile Club (SAAC)', description: 'Membership and event details not verified. Facebook groups and member counts also unverified.', source: 'https://www.saac.com/', confidence: 'unverified' },
];
