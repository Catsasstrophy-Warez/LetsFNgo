/**
 * "Ask the data": an offline, rule-based question box. Keyword intent matching over the sourced collections only —
 * no network, no language model. Every answer is a list of existing records with their source and confidence; a
 * question no rule covers (or a rule with no matching record) answers "not in the data".
 */
import { specs } from '../data/specs';
import { maintenance } from '../data/maintenance';
import { performance } from '../data/performance';
import { colors } from '../data/colors';
import { recalls } from '../data/recalls';
import { prices } from '../data/pricing';
import type { Confidence } from '../data/types';

export interface AskFact { label: string; value: string; source: string; confidence: Confidence; note?: string; route: string }
export type Intent = 'oil' | 'zeroSixty' | 'quarter' | 'paint' | 'recalls' | 'power' | 'torque' | 'topSpeed' | 'tires' | 'weight' | 'msrp' | 'fuel';
export interface Answer { intent: Intent; facts: AskFact[] }

/** Lowercase, strip accents and punctuation (so Spanish "aceite" / "pintura" and "0–60" match). */
export function normQ(q: string): string {
  return q.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[–—]/g, '-').replace(/[^a-z0-9\- ]+/g, ' ').replace(/\s+/g, ' ').trim();
}

const RULES: [Intent, RegExp][] = [
  ['paint', /\b(paint|color|colour|pintura|codigo de color)\b/],
  ['oil', /\b(oil|aceite|lubricante)\b/],
  ['zeroSixty', /\b0 ?-? ?60\b|\bzero to sixty\b|\b0 ?- ?100 ?km\b|\b0 a 60\b/],
  ['quarter', /\bquarter|1 ?\/ ?4|cuarto de milla\b/],
  ['recalls', /\b(recalls?|retiros?|llamad[ao]s? a revision|campanas?|tsb)\b/],
  ['power', /\b(horsepower|hp|power|potencia|caballos)\b/],
  ['torque', /\b(torque|par motor)\b/],
  ['topSpeed', /\b(top speed|velocidad maxima|vmax)\b/],
  ['tires', /\b(tires?|tyres?|llantas?|neumaticos?)\b/],
  ['weight', /\b(weight|weigh|peso|curb)\b/],
  ['msrp', /\b(msrp|price|cost|precio|cuesta|cuanto)\b/],
  ['fuel', /\b(mpg|fuel economy|consumo|tank|tanque|deposito)\b/],
];

const spec = (id: string): AskFact[] => specs.filter((s) => s.id === id && s.value !== null).map((s) => ({ label: s.label, value: `${s.value}${s.unit ? ` ${s.unit}` : ''}`, source: s.source, confidence: s.confidence, note: s.note, route: '/specs' }));
const yearIn = (q: string) => { const m = /\b(2020|2021|2022)\b/.exec(q); return m ? Number(m[1]) : null; };

/** Colors whose name words appear in the question (e.g. "paint code for grabber lime"). */
export function matchColors(q: string) {
  const stop = new Set(['tinted', 'clearcoat', 'metallic', 'tri', 'coat', 'tri-coat', 'ford']);
  return colors.map((c) => {
    const words = normQ(c.name).split(' ').filter((w) => w.length > 2 && !stop.has(w));
    const hits = words.filter((w) => new RegExp(`\\b${w}\\b`).test(q)).length;
    return { c, hits, all: hits === words.length };
  }).filter((x) => x.hits > 0).sort((a, b) => Number(b.all) - Number(a.all) || b.hits - a.hits);
}

function answerFor(intent: Intent, q: string): AskFact[] {
  switch (intent) {
    case 'oil': return maintenance.filter((m) => ['oil-type', 'oil-cap', 'oil-filter', 'intervals'].includes(m.id) && m.value !== null)
      .map((m) => ({ label: m.item, value: `${m.value}${m.unit ? ` ${m.unit}` : ''}`, source: m.source, confidence: m.confidence, note: m.note, route: '/parts' }));
    case 'zeroSixty': return performance.filter((p) => p.category === 'acceleration' && /0.60/.test(p.label)).map((p) => ({ label: p.label, value: `${p.result} (${p.car}${p.date ? `, ${p.date}` : ''})`, source: p.source, confidence: p.confidence, note: p.note, route: '/performance' }));
    case 'quarter': return performance.filter((p) => p.category === 'quarter-mile').map((p) => ({ label: p.label, value: `${p.result} (${p.car}${p.date ? `, ${p.date}` : ''})`, source: p.source, confidence: p.confidence, note: p.note, route: '/performance' }));
    case 'paint': {
      // Question words like "code" must not match a color name (Code Orange).
      const m = matchColors(q.replace(/\b(paint|color|colour|code|codigo|pintura|what|is|the|for|de|del|cual|es)\b/g, ' '));
      const best = m.length ? m.filter((x) => x.hits === m[0].hits && x.all === m[0].all).map((x) => x.c) : [];
      return best.map((c) => ({ label: `${c.name} (${c.years.join(', ')})`, value: c.code ?? 'code not in the data', source: c.source, confidence: c.confidence, note: c.note, route: '/colors' }));
    }
    case 'recalls': return recalls.filter((r) => r.appliesToGT500 === 'yes' || r.appliesToGT500 === 'likely')
      .map((r) => ({ label: `${r.campaign ?? r.id}: ${r.title}`, value: `${r.appliesToGT500 === 'yes' ? 'Applies to GT500' : 'Likely applies to GT500'}${r.years ? ` (${r.years})` : ''} — ${r.summary}`, source: r.source, confidence: r.confidence, note: r.evidence, route: '/ownership' }));
    case 'power': return spec('hp');
    case 'torque': return spec('tq');
    case 'topSpeed': return spec('top-speed');
    case 'tires': return [...spec('tires'), ...spec('tire-f'), ...spec('tire-r')];
    case 'weight': return spec('curb-weight');
    case 'fuel': return [...spec('mpg'), ...spec('tank')];
    case 'msrp': {
      const y = yearIn(q);
      return prices.filter((p) => p.kind === 'msrp' && p.value !== null && (!y || p.year === y)).map((p) => ({ label: `${p.year} ${p.label}`, value: `$${p.value!.toLocaleString('en-US')}`, source: p.source, confidence: p.confidence, note: p.note, route: '/packages' }));
    }
  }
}

/** Answer a question from the data, or null ("not in the data"). */
export function ask(question: string): Answer | null {
  const q = normQ(question);
  if (!q) return null;
  for (const [intent, re] of RULES) {
    if (!re.test(q)) continue;
    const facts = answerFor(intent, q);
    return facts.length ? { intent, facts } : null;
  }
  return null;
}

export const EXAMPLES = ['What oil does it take?', '0-60 time', 'Paint code for Grabber Lime', 'Recalls', 'Horsepower', '2021 MSRP', 'Tire size'];
