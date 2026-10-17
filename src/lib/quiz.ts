import { specs } from '../data/specs';
import { colors } from '../data/colors';
import { performance } from '../data/performance';
import { production } from '../data/production';
import { prices } from '../data/pricing';
import type { Confidence } from '../data/types';
import { load, save } from './storage';
import { EMPTY_SCORE, normScore, type QuizScore } from './validate';

export const QUIZ_KEY = 'gt500.quiz.v1';
export const loadScore = (): QuizScore => normScore(load<unknown>(QUIZ_KEY, null));
export const saveScore = (s: QuizScore) => save(QUIZ_KEY, s);

export interface Question { id: string; prompt: string; choices: string[]; answer: number; source: string; confidence: Confidence; fact: string }

/** Deterministic PRNG so a seed always yields the same quiz (and tests are stable). */
export function rng(seed: number) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
function shuffle<T>(xs: T[], r: () => number): T[] {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

const usable = (c: Confidence) => c === 'confirmed' || c === 'reported';
const n = (x: number) => x.toLocaleString('en-US');

/** Wrong options for a number: nearby values, never equal to the right answer. */
function numericDistractors(v: number): number[] {
  const step = v >= 1000 ? 100 : v >= 100 ? 10 : v >= 10 ? 1 : 0.1;
  const r = (x: number) => Math.round(x / step) * step;
  return [...new Set([r(v * 0.88), r(v * 1.09), r(v * 1.18), r(v * 0.8)])].filter((x) => x !== v && x > 0).slice(0, 3);
}

function mk(id: string, prompt: string, right: string, wrong: string[], r: () => number, src: { source: string; confidence: Confidence }, fact: string): Question | null {
  const w = [...new Set(wrong.filter((x) => x !== right))].slice(0, 3);
  if (w.length < 2) return null;
  const choices = shuffle([right, ...w], r);
  return { id, prompt, choices, answer: choices.indexOf(right), source: src.source, confidence: src.confidence, fact };
}

/**
 * Build the full question pool. Every question's correct answer is a confirmed or reported record;
 * unverified records are never used. Distractors are other records' values or nearby numbers.
 */
export function buildQuestions(seed = 1): Question[] {
  const r = rng(seed);
  const out: (Question | null)[] = [];
  for (const s of specs) {
    if (!usable(s.confidence) || s.value === null || s.conflicts) continue;
    if (typeof s.value === 'number') {
      const unit = s.unit ? ` ${s.unit}` : '';
      out.push(mk(`spec-${s.id}`, `What is the GT500's ${s.label.toLowerCase()}?`, `${n(s.value)}${unit}`, numericDistractors(s.value).map((x) => `${n(x)}${unit}`), r, s, `${s.label}: ${n(s.value)}${unit}`));
    } else {
      const same = specs.filter((o) => o.system === s.system && o.id !== s.id && typeof o.value === 'string').map((o) => String(o.value));
      out.push(mk(`spec-${s.id}`, `${s.label}: which is correct for the GT500?`, s.value, shuffle(same, r), r, s, `${s.label}: ${s.value}`));
    }
  }
  const coded = colors.filter((c) => c.code);
  for (const c of coded) {
    if (!usable(c.confidence)) continue;
    out.push(mk(`code-${c.id}`, `What is the paint code for ${c.name}?`, c.code!, shuffle(coded.filter((o) => o.id !== c.id).map((o) => o.code!), r), r, c, `${c.name} = ${c.code}`));
  }
  for (const p of performance) {
    if (!usable(p.confidence)) continue;
    const others = performance.filter((o) => o.category === p.category && o.id !== p.id).map((o) => o.result);
    out.push(mk(`perf-${p.id}`, `${p.label}: what was the sourced result?`, p.result, shuffle(others, r), r, p, `${p.label}: ${p.result}`));
  }
  for (const p of production) {
    if (!usable(p.confidence) || typeof p.value !== 'number') continue;
    out.push(mk(`prod-${p.id}`, `${p.label}: how many?`, n(p.value), numericDistractors(p.value).map(n), r, p, `${p.label}: ${n(p.value)}${p.note ? ` (${p.note})` : ''}`));
  }
  for (const p of prices) {
    if (p.confidence !== 'confirmed' || p.value === null) continue;
    out.push(mk(`price-${p.id}`, `${p.year} ${p.label}: how much?`, `$${n(p.value)}`, numericDistractors(p.value).map((x) => `$${n(x)}`), r, p, `${p.year} ${p.label}: $${n(p.value)}`));
  }
  return out.filter((q): q is Question => q !== null);
}

/** A round of `count` questions drawn from the pool. */
export const quizRound = (seed: number, count = 10) => shuffle(buildQuestions(seed), rng(seed + 7)).slice(0, count);

export function recordAnswer(s: QuizScore, correct: boolean): QuizScore {
  const streak = correct ? s.streak + 1 : 0;
  return { answered: s.answered + 1, correct: s.correct + (correct ? 1 : 0), streak, bestStreak: Math.max(s.bestStreak, streak) };
}
export { EMPTY_SCORE };
