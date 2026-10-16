/**
 * Mod compatibility and order-of-operations rules for the Build planner.
 * Every rule is derived from sourced records already in the app (mods.ts, specs.ts); nothing here
 * adds a new fact. Each warning carries the records it is based on so the UI can cite them.
 */
import { modStages } from '../data/mods';
import { specs } from '../data/specs';
import type { ModStage, SpecFact } from '../data/types';

export type Severity = 'warn' | 'info';
export interface CompatWarning {
  id: string; severity: Severity; title: string; text: string;
  /** Selected mods that triggered the rule. */
  mods: ModStage[];
  /** Sourced records the rule rests on (cite each). */
  basis: { label: string; source: string; confidence: ModStage['confidence'] }[];
}

const byId = (id: string) => modStages.find((m) => m.id === id);
const spec = (id: string) => specs.find((s) => s.id === id) as SpecFact | undefined;

/** Wheel/rear-wheel torque figures (lb-ft) quoted in a mod's sourced result text, e.g. "746 lb-ft", "753 rwtq". */
export function quotedTorque(m: ModStage): number[] {
  const out: number[] = [];
  const re = /([\d,]{3,5})\s*(?:lb-ft|rwtq)/g;
  let x: RegExpExecArray | null;
  while ((x = re.exec(m.result))) out.push(Number(x[1].replace(/,/g, '')));
  // "954 rwhp / 718 lb-ft" style pairs are covered above; plain "/ 869 rwtq" too.
  return out;
}

/** The low end of the sourced (forum, unverified) DCT clutch torque rating. */
export function dctRatingLow(): number | null {
  const s = spec('clutch-rating');
  const m = s && typeof s.value === 'string' ? s.value.match(/\d[\d,]*/) : null;
  return m ? Number(m[0].replace(/,/g, '')) : null;
}

const usesE85 = (m: ModStage) => /\bE85\b/.test(m.parts) || /\bE85\b/.test(m.result);
/** Fuel-system parts a source lists alongside E85 for that build. */
export function fuelParts(m: ModStage): string[] {
  return m.parts.split(/,\s*/).filter((p) => /fuel|injector|pump/i.test(p));
}
const replacesBlower = (m: ModStage) => /blower|twin-turbo/i.test(m.stage);
const raceFuel = (m: ModStage) => /race fuel|MS109/i.test(m.parts);

/** Stage number from the sourced "N · Name" label (exhaust and other unnumbered items sort last). */
export const stageNumber = (m: ModStage) => { const n = Number(m.stage.match(/^(\d+)/)?.[1]); return Number.isFinite(n) ? n : 9; };

/** Suggested order: by the stage number the source data assigns. Stable for ties. */
export function orderOfOps(mods: ModStage[]): ModStage[] {
  return mods.map((m, i) => ({ m, i })).sort((a, b) => stageNumber(a.m) - stageNumber(b.m) || a.i - b.i).map((x) => x.m);
}

export function checkPlan(mods: ModStage[]): CompatWarning[] {
  const out: CompatWarning[] = [];
  const rating = dctRatingLow();
  const ratingSpec = spec('clutch-rating');
  const dct = byId('dct');
  // 1. DCT clutch rating vs high-torque builds.
  if (rating !== null && ratingSpec) {
    const over = mods.filter((m) => quotedTorque(m).some((t) => t > rating));
    if (over.length) {
      const basis = [{ label: `DCT clutch torque rating ${ratingSpec.value} ${ratingSpec.unit ?? ''}`.trim(), source: ratingSpec.source, confidence: ratingSpec.confidence }];
      if (dct) basis.push({ label: dct.stage, source: dct.source, confidence: dct.confidence });
      const lines = byId('dct-lines');
      if (lines) basis.push({ label: lines.stage, source: lines.source, confidence: lines.confidence });
      out.push({
        id: 'dct-torque', severity: 'warn', title: 'Torque above the reported DCT clutch rating',
        text: `${over.map((m) => `${m.stage.replace(/^[\d·\s]+/, '')} (${quotedTorque(m).join(' / ')} lb-ft at the wheels)`).join('; ')} exceed${over.length === 1 ? 's' : ''} the ≈${rating} lb-ft TR-9070 clutch rating that forum posters report. That rating is unverified — no Ford or TREMEC figure was found — and no GT500 clutch upgrade is confirmed.`,
        mods: over, basis,
      });
    }
  }
  // 2. E85 builds: list the fuel-system parts each source used.
  const e85 = mods.filter(usesE85);
  if (e85.length) {
    out.push({
      id: 'e85-fuel', severity: 'warn', title: 'E85 needs the fuel-system parts its source lists',
      text: e85.map((m) => { const p = fuelParts(m); return `${m.stage.replace(/^[\d·\s]+/, '')}: ${p.length ? p.join(', ') : 'source lists no fuel parts'}`; }).join('; ') + '. Fuel parts are part of these sourced builds; a tune alone was not shown running E85.',
      mods: e85, basis: e85.map((m) => ({ label: m.stage, source: m.source, confidence: m.confidence })),
    });
  }
  // 3. Only one forced-induction replacement.
  const fi = mods.filter(replacesBlower);
  if (fi.length > 1) {
    out.push({
      id: 'one-blower', severity: 'warn', title: 'More than one supercharger / turbo replacement',
      text: `${fi.map((m) => m.stage.replace(/^[\d·\s]+/, '')).join(', ')} each replace the stock blower, so a plan can use only one.`,
      mods: fi, basis: fi.map((m) => ({ label: m.stage, source: m.source, confidence: m.confidence })),
    });
  }
  // 4. Race-fuel builds.
  const rf = mods.filter(raceFuel);
  if (rf.length) {
    out.push({
      id: 'race-fuel', severity: 'info', title: 'Sourced result used race fuel',
      text: `${rf.map((m) => m.stage.replace(/^[\d·\s]+/, '')).join(', ')}: the quoted figure is on race fuel (${rf.map((m) => m.parts.match(/MS109[^,]*/)?.[0] ?? 'race fuel').join(', ')}), not pump gas.`,
      mods: rf, basis: rf.map((m) => ({ label: m.stage, source: m.source, confidence: m.confidence })),
    });
  }
  return out;
}
