import type { ModStage } from './types';

export const modStages: ModStage[] = [
  { id: 'tune', stage: '1 · Tune', parts: 'Palm Beach Dyno 93-octane tune, 8,000 rpm limiter', result: '≈ +56 whp (tune only)', source: 'https://themustangsource.com/?p=34098', confidence: 'reported' },
  { id: 'pulley', stage: '2 · Pulley + fuel + E85', parts: '2.8 pulley, E85, fuel-system upgrades', result: '754 whp / 746 lb-ft first pull', source: 'https://www.fordmuscle.com/?p=29773', confidence: 'unverified', note: 'Unclear whether this car was an S550 GT500.' },
  { id: 'vmp', stage: '3 · Blower upgrade (VMP Apex Predator)', parts: 'VMP upgraded blower, larger injectors, pump voltage booster, ~16 psi', result: '908 rwhp pump gas; 954 rwhp / 718 lb-ft E85', source: 'https://www.fordmuscle.com/news/vmp-pushes-an-apex-predator-upgraded-gt500-to-954-rwhp-with-e85/', confidence: 'reported' },
  { id: 'whipple', stage: '3 · Blower swap (Whipple 3.8L)', parts: 'Whipple WK-2550-38, ~$8,100–8,850, CARB EO D-231-84 (MY2020–22)', result: 'Up to 1,035 hp claimed @ 16 psi, 93 octane, stock engine', source: 'https://whipplesuperchargers.com/i-2046', confidence: 'reported', note: 'Listings conflict on Gen 5 vs Gen 6 blower.' },
  { id: 'dct', stage: '4 · DCT limits', parts: 'Clutch upgrade (no verified vendor found)', result: 'Clutch rating ≈ 664–700 lb-ft per forum posters', source: 'https://www.mustang6g.com/forums/threads/dct-performance.128063/post-2650750', confidence: 'unverified', note: '"Upgrade needed above ~800 wheel lb-ft" is speculation.' },
  { id: 'x-810', stage: 'Excluded', parts: '"~810–820 whp tune-only"', result: 'Unsourced — not used', source: 'https://themustangsource.com/?p=34098', confidence: 'unverified', status: 'excluded' },
  { id: 'x-pbd1100', stage: 'Excluded', parts: '"PBD ~1,100 rwhp / 9.035 s"', result: 'Attribution not confirmed — not published', source: 'https://www.fordmuscle.com/?p=938086', confidence: 'unverified', status: 'excluded' },
  { id: 'x-whipple23', stage: 'Excluded', parts: '"Whipple 2.3L" in PBD 8.8 s build', result: 'Smaller than the stock 2.65L — blower listed as unknown', source: 'https://themustangsource.com/?p=38704', confidence: 'unverified', status: 'excluded' },
];

export const warrantyNote = {
  text: 'Under the Magnuson-Moss Act, as forum readers interpret it, Ford must show a modification caused a failure before denying a claim. Aftermarket parts themselves are never covered. No GT500 denial case or CARB EOs for tunes/exhausts were found. Not legal advice.',
  source: 'https://www.mustang6g.com/forums/threads/will-a-tune-void-warranty-no.210386/',
  confidence: 'reported' as const,
};
