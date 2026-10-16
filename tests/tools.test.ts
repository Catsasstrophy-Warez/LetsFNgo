import { describe, expect, it } from 'vitest';
import { GT500_FINAL, GT500_RATIOS, GT500_REAR_TIRE, GT500_REDLINE, mphAt, parseRatios, parseTireSize, rpmAt, tireDiameterIn } from '../src/lib/gearing';
import { foxQuarter, haleQuarter, powerToWeight } from '../src/lib/perf';
import { formatLapTime, lapStats, parseLapTime, parseLaps } from '../src/lib/laptime';
import { nextDue, reminderStatus, type Reminder } from '../src/lib/garage';
import { summarizePlan, plannable } from '../src/lib/planner';
import { makeBackup, parseBackup, validateBackup } from '../src/lib/backup';
import { EMPTY_GARAGE } from '../src/lib/garage';
import { referenceLaps } from '../src/lib/refLaps';
import { search } from '../src/lib/search';

describe('gearing', () => {
  it('reads sourced ratios, final drive, redline and tire', () => {
    expect(GT500_RATIOS).toEqual([3.14, 2.05, 1.43, 1.1, 0.86, 0.68, 0.56]);
    expect(parseRatios('3.14 / 2.05 · R 2.76')).toEqual([3.14, 2.05]);
    expect(GT500_FINAL).toBe(3.73);
    expect(GT500_REDLINE).toBe(7500);
    expect(GT500_REAR_TIRE).toBe('315/30R20');
  });
  it('parses tire sizes and computes diameter', () => {
    expect(parseTireSize('315/30ZR20')).toEqual({ width: 315, aspect: 30, rim: 20 });
    expect(parseTireSize('nope')).toBeNull();
    expect(tireDiameterIn(parseTireSize('315/30R20')!)).toBeCloseTo(27.44, 2);
  });
  it('mph and rpm are inverses and match hand math', () => {
    const d = tireDiameterIn(parseTireSize('315/30R20')!);
    const first = mphAt(7500, 3.14, 3.73, d);
    expect(first).toBeCloseTo(52.28, 2);
    expect(rpmAt(first, 3.14, 3.73, d)).toBeCloseTo(7500, 6);
    expect(mphAt(1000, 1, 1, 26.9)).toBeCloseTo(80.0, 1);
  });
});

describe('performance estimates', () => {
  it('Hale and Fox formulas', () => {
    const h = haleQuarter(3000, 300)!;
    expect(h.et).toBeCloseTo(5.825 * Math.cbrt(10), 6);
    expect(h.mph).toBeCloseTo(234 / Math.cbrt(10), 6);
    const f = foxQuarter(4405, 760)!;
    expect(f.et).toBeGreaterThan(10); expect(f.et).toBeLessThan(12.5);
    expect(haleQuarter(0, 300)).toBeNull();
  });
  it('power to weight', () => {
    const p = powerToWeight(4000, 800)!;
    expect(p.lbPerHp).toBe(5);
    expect(p.hpPerTon).toBe(400);
    expect(powerToWeight(4000, -1)).toBeNull();
  });
});

describe('lap time parsing and stats', () => {
  it('parses formats', () => {
    expect(parseLapTime('1:33.84')).toBeCloseTo(93.84, 6);
    expect(parseLapTime('2:44.6')).toBeCloseTo(164.6, 6);
    expect(parseLapTime('59.123')).toBeCloseTo(59.123, 6);
    expect(parseLapTime('1:02:03.5')).toBeCloseTo(3723.5, 6);
    expect(parseLapTime(' 1:05 ')).toBe(65);
    for (const bad of ['', 'abc', '1:75.0', '1::2', '-1:00', '0', '1:2:3:4', '1:60:00']) expect(parseLapTime(bad), bad).toBeNull();
  });
  it('formats', () => {
    expect(formatLapTime(93.84)).toBe('1:33.840');
    expect(formatLapTime(65.5)).toBe('1:05.500');
    expect(formatLapTime(9.1, 2)).toBe('09.10');
    expect(formatLapTime(null)).toBe('—');
  });
  it('parses lap lists with sectors and reports bad lines', () => {
    const r = parseLaps('1:36.0 | 30 33 33\n\n1:35.0 | 31 31 33\nbad\n1:35.5 | 30 x 1');
    expect(r.laps.length).toBe(2);
    expect(r.bad).toEqual([4, 5]);
  });
  it('best / avg / theoretical', () => {
    const s = lapStats(parseLaps('1:36.0 | 30 33 33\n1:35.0 | 31 31 33').laps);
    expect(s.best).toBe(95); expect(s.avg).toBe(95.5); expect(s.theoretical).toBe(94); expect(s.count).toBe(2);
    expect(lapStats(parseLaps('1:36\n1:35 | 30 30 35').laps).theoretical).toBeNull();
    expect(lapStats([])).toEqual({ count: 0, best: null, avg: null, theoretical: null });
  });
  it('matches sourced reference laps', () => {
    expect(referenceLaps('WeatherTech Laguna Seca').map((r) => r.seconds)).toEqual([93.84, 93.8]);
    expect(referenceLaps('VIR Grand Course').length).toBe(2);
    expect(referenceLaps('Road Atlanta')).toEqual([]);
  });
});

describe('maintenance reminders', () => {
  const r: Reminder = { id: 'x', item: 'Oil', everyMiles: 5000, everyMonths: 12, lastMiles: 10000, lastDate: '2026-01-31' };
  it('computes due by miles and months', () => {
    const s = reminderStatus(r, 12000, '2026-06-01');
    expect(s).toMatchObject({ state: 'ok', dueMiles: 15000, dueDate: '2027-01-31', milesLeft: 3000 });
    expect(reminderStatus(r, 14700, '2026-06-01').state).toBe('soon');
    expect(reminderStatus(r, 15000, '2026-06-01').state).toBe('overdue');
    expect(reminderStatus(r, 11000, '2027-02-01').state).toBe('overdue');
    expect(reminderStatus(r, 11000, '2027-01-10').state).toBe('soon');
    expect(reminderStatus({ ...r, lastMiles: null, lastDate: '' }, 11000, '2026-06-01').state).toBe('unknown');
    expect(reminderStatus({ ...r, everyMonths: 1, lastDate: '2026-01-31' }, null, '2026-02-01').dueDate).toBe('2026-02-28');
  });
  it('picks the most urgent', () => {
    const a = { ...r, id: 'a', item: 'A' };
    const b = { ...r, id: 'b', item: 'B', lastMiles: 6000 };
    expect(nextDue([a, b], 12000, '2026-06-01')!.reminder.id).toBe('b');
    expect(nextDue([], 0, '2026-06-01')).toBeNull();
  });
});

describe('build planner', () => {
  it('sums only sourced prices and never invents hp', () => {
    const s = summarizePlan(['whipple', 'borla', 'tune', 'x-810']);
    expect(s.mods.map((m) => m.id)).toEqual(['whipple', 'borla', 'tune']);
    expect(s.costMin).toBeCloseTo(10899.99, 2);
    expect(s.costMax).toBeCloseTo(12419.99, 2);
    expect(s.unpricedCount).toBe(1);
    expect(plannable.some((m) => m.status === 'excluded')).toBe(false);
    expect(Object.keys(s)).not.toContain('hp');
  });
});

describe('backup', () => {
  it('round-trips and validates', () => {
    const b = makeBackup({ ...EMPTY_GARAGE, nickname: 'Snake' }, [{ id: 'p', name: 'P', modIds: ['tune'], created: '2026-01-01' }],
      [{ id: 't', date: '2026-01-01', track: 'VIR', conditions: '', airTemp: '', pressures: { fl: '32', fr: '32', rl: '30', rr: '30' }, laps: '2:50.1', notes: '' }]);
    const r = parseBackup(JSON.stringify(b));
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.data.garage.nickname).toBe('Snake'); expect(r.data.schema).toBe(1); expect(r.data.track[0].pressures.rr).toBe('30'); }
  });
  it('fills defaults for older garage data', () => {
    const r = validateBackup({ app: 'gt500-companion', schema: 1, garage: { vin: '', mods: [] }, plans: [], track: [{ id: 'a', date: 'd', track: 'x', laps: '', pressures: {} }] });
    expect(r.ok).toBe(true);
    if (r.ok) { expect(r.data.garage.reminders.length).toBeGreaterThan(0); expect(r.data.track[0].pressures.fl).toBe(''); }
  });
  it('rejects bad input', () => {
    expect(parseBackup('{').ok).toBe(false);
    const r = validateBackup({ app: 'other', schema: 99, garage: { mods: [{}] }, plans: 'x', track: [] });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.errors.length).toBeGreaterThanOrEqual(4);
  });
});

describe('search', () => {
  it('finds tools', () => {
    expect(search('quarter mile estimator').some((h) => h.route === '/tools')).toBe(true);
    expect(search('lap times').some((h) => h.route === '/track')).toBe(true);
  });
});
