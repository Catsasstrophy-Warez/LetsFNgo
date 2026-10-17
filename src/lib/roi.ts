import type { ModStage } from '../data/types';

export type RoiRow =
  | { mod: ModStage; ok: true; gainWhp: number; costMin: number; costMax: number; perHpMin: number; perHpMax: number }
  | { mod: ModStage; ok: false; missing: ('gain' | 'price')[] };

/**
 * Dollars per wheel-horsepower for each mod, using only a sourced price range (`cost`) and a sourced
 * gain (`gain`). Anything missing either is reported as insufficient data — nothing is estimated.
 */
export function costPerHp(mods: ModStage[]): RoiRow[] {
  return mods.map((mod) => {
    const missing: ('gain' | 'price')[] = [];
    if (!mod.gain || !(mod.gain.whp > 0)) missing.push('gain');
    if (!mod.cost) missing.push('price');
    if (missing.length || !mod.gain || !mod.cost) return { mod, ok: false as const, missing };
    const g = mod.gain.whp;
    return { mod, ok: true as const, gainWhp: g, costMin: mod.cost.min, costMax: mod.cost.max, perHpMin: mod.cost.min / g, perHpMax: mod.cost.max / g };
  });
}
