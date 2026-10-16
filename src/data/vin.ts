import type { VinPosition } from './types';

const MA = 'https://mustangattitude.com/mustang/2020mustang.shtml';

export const vinPositions: VinPosition[] = [
  { positions: '1–3', meaning: '1FA — Ford, USA, passenger car', source: MA, confidence: 'reported' },
  { positions: '4', meaning: 'Restraint system code (6 on sample VINs)', source: MA, confidence: 'unverified', note: 'Inferred from standard Ford convention; verify with NHTSA vPIC.' },
  { positions: '5–7', meaning: 'P8S — Shelby GT500 fastback (P8J = GT350)', source: MA, confidence: 'reported' },
  { positions: '8', meaning: 'J — 5.2L supercharged V8 (760 hp / 625 lb-ft)', source: MA, confidence: 'reported' },
  { positions: '9', meaning: 'Check digit (NHTSA 49 CFR 565 algorithm)', source: 'https://www.ecfr.gov/current/title-49/subtitle-B/chapter-V/part-565', confidence: 'confirmed' },
  { positions: '10', meaning: 'Model year: L = 2020, M = 2021, N = 2022', source: MA, confidence: 'reported' },
  { positions: '11', meaning: 'Plant: 5 — Flat Rock, MI (inferred from sample VINs)', source: 'https://forcar.org/vin-check/1FA6P8SJ1L5504855/', confidence: 'unverified', note: 'Verify with NHTSA vPIC.' },
  { positions: '12–17', meaning: 'Sequential serial; sample GT500s start near 500000', source: 'https://forcar.org/vin-check/1FA6P8SJ6M5500608/', confidence: 'reported' },
];

export const sampleVins = ['1FA6P8SJ1L5504855', '1FA6P8SJ6M5500608'];
export const VPIC_URL = 'https://vpic.nhtsa.dot.gov/decoder/';
