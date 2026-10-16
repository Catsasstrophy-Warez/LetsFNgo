import { modStages } from '../data/mods';
import type { ModStage } from '../data/types';

export const plannable = modStages.filter((m) => m.status !== 'excluded');

export interface PlanSummary { mods: ModStage[]; costMin: number; costMax: number; pricedCount: number; unpricedCount: number }

/** Sum only the price ranges that sources list. Horsepower is never combined — gains are per-source and not additive. */
export function summarizePlan(modIds: string[]): PlanSummary {
  const mods = modIds.map((id) => plannable.find((m) => m.id === id)).filter((m): m is ModStage => !!m);
  const priced = mods.filter((m) => m.cost);
  return {
    mods,
    costMin: priced.reduce((a, m) => a + m.cost!.min, 0),
    costMax: priced.reduce((a, m) => a + m.cost!.max, 0),
    pricedCount: priced.length,
    unpricedCount: mods.length - priced.length,
  };
}
