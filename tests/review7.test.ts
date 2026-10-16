import { describe, expect, it, vi } from 'vitest';
import { formatUnitInput, parseUnitInput, fromDisplay, toDisplay, type Kind } from '../src/lib/units';
import { _resetForTests, applyUpdate, watchRegistration, type RegLike } from '../src/lib/sw';
import { analyzeRun, cleanFixes, syntheticTrace } from '../src/lib/gps';
import { reminderStatus, type Reminder } from '../src/lib/garage';
import { createWakeLock, type Sentinel } from '../src/lib/wakelock';

describe('code review fixes (round 7)', () => {
  it('unit inputs never show or store NaN (0 mpg has no L/100 km value)', () => {
    expect(formatUnitInput('economy', 0, 'metric', 1)).toBe('');
    expect(parseUnitInput('economy', '0', 'metric')).toBeNull();
    expect(parseUnitInput('distance', ' 1,000 ', 'imperial')).toBe(1000);
    expect(parseUnitInput('distance', 'abc', 'metric')).toBeNull();
    expect(parseUnitInput(null, '', 'metric')).toBeNull();
  });
  it('every unit kind round-trips display ↔ base', () => {
    const kinds: Kind[] = ['distance', 'speed', 'weight', 'length', 'volume', 'temp', 'pressure', 'altitude', 'torque', 'economy', 'shortLength'];
    for (const k of kinds) for (const v of [1, 14.5, 760, -40]) {
      if (k === 'economy' && v <= 0) continue;
      expect(fromDisplay(k, toDisplay(k, v, 'metric'), 'metric')).toBeCloseTo(v, 9);
    }
  });
  it('SW update: tapping Reload twice reloads only once', () => {
    _resetForTests();
    const listeners: (() => void)[] = [];
    const w = { postMessage: vi.fn() } as unknown as ServiceWorker;
    const reg: RegLike = { waiting: w, installing: null, addEventListener: () => undefined };
    watchRegistration(reg, () => true);
    const container = { addEventListener: (_t: string, f: () => void) => { listeners.push(f); } } as unknown as Pick<ServiceWorkerContainer, 'addEventListener'>;
    const reload = vi.fn();
    applyUpdate(container, reload); applyUpdate(container, reload);
    listeners.forEach((f) => f());
    expect(reload).toHaveBeenCalledTimes(1);
    _resetForTests();
  });
  it('GPS: duplicate/out-of-order fixes do not fake a launch mid-run', () => {
    const tr = syntheticTrace({ accelMps2: 8, seconds: 14, useSpeed: false, hz: 2 });
    const clean = analyzeRun('quarter', tr);
    // Redeliver a cached fix (same timestamp) and shuffle two samples.
    const dup = [...tr.slice(0, 8), { ...tr[7] }, ...tr.slice(8)];
    [dup[10], dup[11]] = [dup[11], dup[10]];
    const r = analyzeRun('quarter', dup);
    expect(clean.ok && r.ok).toBe(true);
    if (clean.ok && r.ok) expect(r.seconds).toBeCloseTo(clean.seconds, 6);
    expect(cleanFixes([{ t: NaN, lat: 0, lon: 0, accuracy: 1, speed: null }])).toEqual([]);
  });
  it('reminders: zero/negative intervals are ignored; years < 100 do not jump to 19xx', () => {
    const base: Reminder = { id: 'x', item: 'Oil', everyMiles: -5000, everyMonths: -3, lastMiles: 1000, lastDate: '2026-01-01' };
    expect(reminderStatus(base, 2000, '2026-02-01').state).toBe('unknown');
    const old = reminderStatus({ ...base, everyMiles: null, everyMonths: 1, lastDate: '0050-01-31' }, null, '0050-02-01');
    expect(old.dueDate).toBe('0050-02-28');
  });
  it('wake lock: overlapping acquire calls hold one sentinel and release it', async () => {
    const released: number[] = [];
    let n = 0;
    const req = () => new Promise<Sentinel>((res) => { const id = ++n; setTimeout(() => res({ release: async () => { released.push(id); } }), 5); });
    const states: string[] = [];
    const lock = createWakeLock(req, (s) => states.push(s));
    await Promise.all([lock.set(true), lock.acquire(), lock.acquire()]);
    expect(n).toBe(1);
    expect(lock.held).toBe(true);
    lock.dispose();
    expect(released).toEqual([1]);
    const none = createWakeLock(null, (s) => states.push(s));
    await none.set(false);
    expect(states).toContain('unsupported');
  });
});
