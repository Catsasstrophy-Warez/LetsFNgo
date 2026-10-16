import { load, save } from './storage';
import { DEFAULT_ONBOARDING, normOnboarding, type Onboarding } from './validate';
import { loadCars, loadGarage, saveGarage, today } from './garage';

export const ONBOARDING_KEY = 'gt500.onboarding.v1';
export const loadOnboarding = (): Onboarding => normOnboarding(load<unknown>(ONBOARDING_KEY, null)) ?? { ...DEFAULT_ONBOARDING };
export const saveOnboarding = (o: Onboarding) => save(ONBOARDING_KEY, o);
export const finishOnboarding = () => saveOnboarding({ done: true, completed: today() });

/** Garage already has user data (so an existing user is never sent through the intro). */
export function garageHasData(): boolean {
  const s = loadCars();
  return s.cars.length > 1 || s.cars.some((g) => !!(g.vin || g.year || g.color || g.nickname || g.odometer || g.mods.length || g.service.length));
}

/** Show the intro only on a true first run. */
export const needsOnboarding = () => !loadOnboarding().done && !garageHasData();

/** Seed the Garage from the intro answers. Empty answers leave existing values untouched. */
export function seedGarage(a: { year: string; color: string; vin: string }): boolean {
  const g = loadGarage();
  return saveGarage({ ...g, year: a.year || g.year, color: a.color || g.color, vin: a.vin.trim().toUpperCase() || g.vin });
}
