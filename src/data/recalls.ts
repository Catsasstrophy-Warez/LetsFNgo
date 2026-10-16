import type { RecallIssue } from './types';

export const NHTSA_LOOKUP = 'https://www.nhtsa.gov/recalls';

export const recalls: RecallIssue[] = [
  { id: 'tc-2020-485', title: 'DRL / body control module software (Canada)', kind: 'recall', campaign: 'Transport Canada 2020-485 (Ford 20C21)', summary: '833 GT350/GT500 built Sep 2016–Jul 2020: BCM software can stop the daytime running lights from turning on.', source: 'https://recalls-rappels.canada.ca/en/alert-recall/transport-canada-recall-2020485', confidence: 'confirmed' },
  { id: 'tensioner', title: 'Secondary timing-chain tensioner', kind: 'service-action', campaign: null, summary: 'Tensioner on the 5.2L may not have been activated at assembly (risk of lost timing / engine failure). Inspect-and-repair for 2020 GT500/GT350, coverage through Apr 30, 2022. Not a formal recall.', source: 'https://themustangsource.com/?p=37802', confidence: 'reported', note: 'Campaign number not retrieved.' },
  { id: 'c105', title: 'DCT concerns / DTCs — connector C105', kind: 'tsb', campaign: null, summary: 'TSB for 2020–21: inspect connector C105 near the RH valve cover for pushed-out terminals or harness damage.', source: 'https://www.mustang6g.com/forums/threads/2020-gt500-and-dtc-codes-concerns.153414/', confidence: 'reported', note: 'TSB number not retrieved.' },
  { id: 'reduced-power', title: '"Powertrain malfunction / reduced power"', kind: 'owner-report', campaign: null, summary: 'Owners report faults, loss of upshifts and "select manual mode", often at the track.', source: 'https://www.mustang6g.com/forums/threads/powertrain-malfunction-reduced-power-anyone-else.177448/', confidence: 'unverified' },
  { id: 'dct-lines', title: 'DCT cooler lines crack or leak', kind: 'vendor-claim', campaign: null, summary: 'A vendor selling a replacement kit claims the hard lines and seals fail.', source: 'https://ffperformance.co/product/spe-motorsport-2020-2022-ford-mustang-gt500-dct-cooler-line-kit', confidence: 'unverified', note: 'Vendor claim, not an independent finding.' },
  { id: '25s-a9', title: 'Rear-view camera recall (Oct 2025)', kind: 'recall', campaign: '25S-A9', summary: 'Mustang rear camera recall; applicability to the GT500 is unconfirmed.', source: 'https://www.mustang6g.com/forums/threads/10-14-25-recall-issued.222174/post-4384572', confidence: 'unverified' },
  { id: 'us-nhtsa', title: 'U.S. NHTSA campaign numbers', kind: 'recall', campaign: null, summary: 'No GT500-specific NHTSA campaign was confirmed. Check your VIN at nhtsa.gov.', source: NHTSA_LOOKUP, confidence: 'unverified' },
];
