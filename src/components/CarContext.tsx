import { createContext, useCallback, useContext, useState } from 'react';
import { save } from '../lib/storage';
import { activeCar, carLabel, carOf, loadCars, setActiveCar } from '../lib/garage';
import { mergeCarList } from '../lib/carlog';
import { colors } from '../data/colors';

export interface CarSummary { id: string; label: string }
/** `version` changes only on an explicit switch, so pages remount with the new car's data (a refresh after an import does not wipe page state). */
export interface CarCtx { active: string; cars: CarSummary[]; /** Paint swatch of the active car, or null (no / other colour). */ swatch?: string | null; version: number; switchCar: (id: string) => void; refresh: () => void }

export const summarize = () => {
  const s = loadCars();
  const a = activeCar(s);
  return { active: a.id, swatch: colors.find((c) => c.id === a.color)?.swatch ?? null, cars: s.cars.map((c, i) => ({ id: c.id, label: carLabel(c, i) })) };
};

export const CarContext = createContext<CarCtx>({ active: 'car1', cars: [], swatch: null, version: 0, switchCar: () => undefined, refresh: () => undefined });
export const useCar = () => useContext(CarContext);

/** App-level car state: the header switcher and every page read the active car from here. */
export function useCarState(): CarCtx {
  const [s, setS] = useState(summarize);
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => {
    setS((cur) => { const n = summarize(); return JSON.stringify(n) === JSON.stringify(cur) ? cur : n; });
  }, []);
  const switchCar = useCallback((id: string) => { setActiveCar(id); setS(summarize()); setVersion((v) => v + 1); }, []);
  return { ...s, version, switchCar, refresh };
}

/**
 * A per-car log: returns the active car's entries and a setter that writes them back into the full list
 * (other cars' entries are kept). Saves immediately.
 */
export function useCarLog<T extends { id: string; carId?: string }>(key: string, loader: () => T[]): [T[], (next: T[] | ((cur: T[]) => T[])) => void] {
  const { active } = useCar();
  const [mine, setMine] = useState<T[]>(() => loader().filter((e) => carOf(e) === active));
  const set = useCallback((next: T[] | ((cur: T[]) => T[])) => {
    setMine((cur) => {
      const n = typeof next === 'function' ? next(cur) : next;
      const merged = mergeCarList(loader(), active, n);
      save(key, merged);
      return merged.filter((e) => carOf(e) === active);
    });
  }, [key, loader, active]);
  return [mine, set];
}
