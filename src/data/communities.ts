import type { Community } from './types';

export const communities: Community[] = [
  { id: 'm6g', name: 'Mustang6G', description: 'Most active hub for 2020+ GT500 and DCT threads.', source: 'https://www.mustang6g.com/forums/threads/dct-performance.128063/post-2650750', confidence: 'confirmed' },
  { id: 'tmo', name: 'Track Mustangs Online', description: 'Track-focused Mustang forum covering the GT500.', source: 'https://trackmustangsonline.com/threads/2020-gt500-kylo.15994/', confidence: 'confirmed' },
  { id: 'shelby-forums', name: 'forums.shelby.com', description: 'Shelby owners forum (much content on older GT500s).', source: 'https://forums.shelby.com/topic/82587-2011-gt500-pulley-tune-or-23-tvs/', confidence: 'reported' },
  { id: 'reddit', name: 'r/GT500', description: 'Exists, but skews toward 2007–14 cars.', source: 'https://reddit.sudovanilla.org/r/GT500', confidence: 'reported' },
  { id: 'track-attack', name: 'GT500 Track Attack', description: 'Free one-day school for new GT500 buyers at the Ford Performance Racing School, Charlotte.', source: 'https://www.autoblog.com/2019/12/12/ford-gt500-track-attack-school/', confidence: 'confirmed' },
  { id: 'svtp', name: 'SVTPerformance, Facebook groups, SAAC, events', description: 'Not verified in research.', source: 'https://www.saac.com/forum/index.php?msg=90658', confidence: 'unverified' },
];
