/** Parse "m:ss.sss", "ss.sss" or "h:mm:ss.s" into seconds. Returns null for anything else. */
export function parseLapTime(input: string): number | null {
  const s = input.trim();
  if (!/^(\d+:){0,2}\d+(\.\d+)?$/.test(s)) return null;
  const parts = s.split(':').map(Number);
  const secs = parts[parts.length - 1];
  if (parts.length > 1 && secs >= 60) return null;
  if (parts.length === 3 && parts[1] >= 60) return null;
  const total = parts.reduce((acc, n) => acc * 60 + n, 0);
  return total > 0 ? total : null;
}

export function formatLapTime(sec: number | null, digits = 3): string {
  if (sec === null || !Number.isFinite(sec)) return '—';
  const m = Math.floor(sec / 60);
  const rest = sec - m * 60;
  const r = rest.toFixed(digits).padStart(digits ? digits + 3 : 2, '0');
  return m ? `${m}:${r}` : r;
}

export interface Lap { time: number; sectors?: number[] }

/**
 * Parse one lap per line. Optional sectors follow a "|" (e.g. "1:35.20 | 30.1 32.0 33.1").
 * Returns parsed laps plus the 1-based line numbers that could not be read.
 */
export function parseLaps(text: string): { laps: Lap[]; bad: number[] } {
  const laps: Lap[] = [];
  const bad: number[] = [];
  text.split(/\r?\n/).forEach((line, i) => {
    if (!line.trim()) return;
    const [t, sec] = line.split('|');
    const time = parseLapTime(t);
    if (time === null) { bad.push(i + 1); return; }
    let sectors: number[] | undefined;
    if (sec && sec.trim()) {
      const ss = sec.trim().split(/[\s,]+/).map(parseLapTime);
      if (ss.some((x) => x === null)) { bad.push(i + 1); return; }
      sectors = ss as number[];
    }
    laps.push(sectors ? { time, sectors } : { time });
  });
  return { laps, bad };
}

export interface LapStats { count: number; best: number | null; avg: number | null; theoretical: number | null }

/** Theoretical best = sum of best sectors; only when every lap has the same number (≥ 2) of sectors. */
export function lapStats(laps: Lap[]): LapStats {
  if (!laps.length) return { count: 0, best: null, avg: null, theoretical: null };
  const times = laps.map((l) => l.time);
  const n = laps[0].sectors?.length ?? 0;
  let theoretical: number | null = null;
  if (n >= 2 && laps.every((l) => l.sectors?.length === n)) {
    theoretical = 0;
    for (let i = 0; i < n; i++) theoretical += Math.min(...laps.map((l) => l.sectors![i]));
  }
  return { count: laps.length, best: Math.min(...times), avg: times.reduce((a, b) => a + b, 0) / times.length, theoretical };
}
