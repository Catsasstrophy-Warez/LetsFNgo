import { load, save } from './storage';
import { KEYS, activeCarId, carOf, forCar, loadCars, removeCarFromStore, saveCars } from './garage';
import { DRAG_KEY } from './drag';
import { FUEL_KEY } from './fuel';
import { DYNO_KEY } from './dyno';
import { loadCost, saveCost } from './costStore';

/** Every per-car log key (entries carry an optional `carId`). */
export const CAR_LOG_KEYS = [KEYS.track, DRAG_KEY, FUEL_KEY, DYNO_KEY] as const;

type WithCar = { id: string; carId?: string };

/**
 * Replace one car's entries in a full log list, keeping every other car's entries untouched and in place.
 * New entries without a `carId` are stamped with the car's id.
 */
export function mergeCarList<T extends WithCar>(all: T[], carId: string, next: T[]): T[] {
  const others = all.filter((e) => carOf(e) !== carId);
  return [...others, ...next.map((e) => (e.carId ? e : { ...e, carId }))];
}

/** Append an entry for the active car to a log stored under `key` (used by the timer and GPS meter). */
export function appendForActiveCar<T extends WithCar>(key: string, all: T[], entry: T): boolean {
  return save(key, [...all, { ...entry, carId: entry.carId ?? activeCarId() }]);
}

/** Drop one car's entries from every log. Raw lists are filtered so even unreadable entries of other cars survive. */
export function purgeCarLogs(carId: string): boolean {
  const cost = loadCost();
  const costOk = carId in cost.cars ? saveCost({ cars: Object.fromEntries(Object.entries(cost.cars).filter(([id]) => id !== carId)) }) : true;
  return costOk && CAR_LOG_KEYS.map((k) => {
    const raw = load<unknown>(k, []);
    if (!Array.isArray(raw)) return true;
    return save(k, raw.filter((e) => !(e && typeof e === 'object' && carOf(e as WithCar) === carId)));
  }).every(Boolean);
}

/** Remove a car and its log entries. Refuses to remove the last car. */
export function deleteCar(carId: string): boolean {
  const next = removeCarFromStore(carId, loadCars());
  if (!next) return false;
  return saveCars(next) && purgeCarLogs(carId);
}

/** Count of entries per log for one car (for confirmations and summaries). */
export function carLogCounts(carId: string, lists: { track: WithCar[]; drag: WithCar[]; fuel: WithCar[]; dyno: WithCar[] }) {
  return { track: forCar(lists.track, carId).length, drag: forCar(lists.drag, carId).length, fuel: forCar(lists.fuel, carId).length, dyno: forCar(lists.dyno, carId).length };
}
