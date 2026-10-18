import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';

const store = new Map<string, string>();
vi.stubGlobal('localStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); } });
afterAll(() => vi.unstubAllGlobals());
beforeEach(() => store.clear());

import { COST_KEY, MAX_COST_CARS, emptyInputs, loadCost, saveCost, withInputs } from '../src/lib/costStore';
import { addCar, loadCars } from '../src/lib/garage';
import { deleteCar } from '../src/lib/carlog';

describe('Round 19 fixes', () => {
  it('deleting a Garage car drops its cost inputs, so a new car past the cap still saves', () => {
    loadCars();
    const id = addCar()!;
    saveCost(withInputs(loadCost(), id, { ...emptyInputs(), annualMiles: 5000 }));
    expect(deleteCar(id)).toBe(true);
    expect(loadCost().cars[id]).toBeUndefined();
    // Simulate many add/delete cycles: the store never exceeds live cars.
    for (let n = 0; n < MAX_COST_CARS + 2; n++) {
      const c = addCar()!;
      saveCost(withInputs(loadCost(), c, { ...emptyInputs(), years: 2 }));
      deleteCar(c);
    }
    const last = addCar()!;
    saveCost(withInputs(loadCost(), last, { ...emptyInputs(), years: 3 }));
    expect(loadCost().cars[last]?.years).toBe(3);
    expect(store.has(COST_KEY)).toBe(true);
  });
  it('Cost totals cell keeps its table semantics (live region is inside, not on, the cell)', () => {
    const src = readFileSync('src/pages/Cost.tsx', 'utf8');
    expect(src).not.toMatch(/<td role="status"/);
  });
});
