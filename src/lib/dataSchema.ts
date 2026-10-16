/**
 * JSON Schemas for every data collection in `src/data`, plus a tiny dependency-free validator for the subset of
 * JSON Schema (2020-12) they use, and the contribution checks run by `npm run validate:data`.
 *
 * The committed files in `schemas/` are generated from `SCHEMAS` (`npm run validate:data -- --write-schemas`);
 * a unit test fails if they drift. Every object schema sets `additionalProperties: false`, so a field added to a
 * type in `src/data/types.ts` must be added here too (or validation fails), which keeps the two in sync.
 */
import type { Sourced } from '../data/types';

export type JsonSchema = { [k: string]: unknown };

const CONFIDENCE = ['confirmed', 'reported', 'unverified'];
const YEARS = [2020, 2021, 2022];
const str: JsonSchema = { type: 'string', minLength: 1 };
const num: JsonSchema = { type: 'number' };
const bool: JsonSchema = { type: 'boolean' };
const https: JsonSchema = { type: 'string', pattern: '^https://\\S+$' };
const nul = (s: JsonSchema): JsonSchema => ({ anyOf: [s, { type: 'null' }] });
const en = (...v: unknown[]): JsonSchema => ({ enum: v });
const arr = (items: JsonSchema, minItems?: number): JsonSchema => ({ type: 'array', items, ...(minItems ? { minItems } : {}) });
const date: JsonSchema = { type: 'string', pattern: '^\\d{4}(-\\d{2}(-\\d{2})?)?$' };
const year: JsonSchema = en(...YEARS);
const research = en('high', 'medium', 'low');

/** Object schema: `req` fields are required, `opt` are optional; source/confidence/note always apply. */
function rec(req: Record<string, JsonSchema>, opt: Record<string, JsonSchema> = {}, sourced = true): JsonSchema {
  const base = sourced ? { source: { $ref: '#/$defs/source' }, confidence: { $ref: '#/$defs/confidence' } } : {};
  return {
    type: 'object',
    required: [...Object.keys(req), ...Object.keys(base)],
    properties: { ...req, ...base, ...opt, ...(sourced ? { note: str } : {}) },
    additionalProperties: false,
  };
}
/** A SourcedValue<T>: `value` may be null only with a note (checked separately). */
const sv = (value: JsonSchema, extra: Record<string, JsonSchema> = {}, extraOpt: Record<string, JsonSchema> = {}) =>
  rec({ ...extra, value: nul(value) }, { context: str, ...extraOpt });
const strnum: JsonSchema = { type: ['string', 'number'] };

const ITEMS: Record<string, JsonSchema> = {
  specs: sv(strnum, { id: str, system: en('Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy', 'Features'), label: str },
    { unit: str, conflicts: arr({ $ref: '#/$defs/conflict' }, 1) }),
  modelYears: rec({ id: str, year: nul(year), name: str, builder: en('Ford', 'Shelby American'), summary: str, changes: arr(str) }),
  colors: rec({ id: str, name: str, code: nul(str), swatch: { type: 'string', pattern: '^#[0-9a-fA-F]{3,8}$' }, years: arr(year) }, { yearsNote: str }),
  packages: rec({ id: str, name: str, years: arr(year), price: { $ref: '#/$defs/numberValue' }, contents: arr(str), contentsConfidence: { $ref: '#/$defs/confidence' } },
    { priceConflicts: arr({ $ref: '#/$defs/numberValue' }, 1) }),
  prices: sv(num, { id: str, year, label: str, kind: en('msrp', 'destination', 'gas-guzzler', 'delivered', 'as-tested') }),
  marketSales: rec({ id: str, date: nul(date), venue: str, description: str, year, amount: num, outcome: en('sold', 'high-bid', 'asking') }),
  production: sv(strnum, { id: str, label: str, scope: str }, { conflicts: arr({ $ref: '#/$defs/conflict' }, 1) }),
  performance: rec({ id: str, category: en('acceleration', 'quarter-mile', 'lap', 'drag-record'), label: str, result: str,
    car: en('stock', 'stock (CFTP)', 'modified', 'Shelby American'), date: nul(date) }),
  recalls: rec({ id: str, title: str, kind: en('recall', 'nhtsa-recall', 'service-action', 'tsb', 'complaint', 'owner-report', 'vendor-claim'), campaign: nul(str), summary: str },
    { years: str, appliesToGT500: en('yes', 'likely', 'no', 'vin'), evidence: str, buildWindow: nul(str) }),
  maintenance: sv(strnum, { id: str, item: str, group: en('Fluids', 'Service', 'Warranty', 'Ownership') },
    { unit: str, conflicts: arr({ $ref: '#/$defs/conflict' }, 1), warning: str }),
  vinPositions: rec({ positions: str, meaning: str }),
  modStages: rec({ id: str, stage: str, parts: str, result: str }, {
    status: { const: 'excluded' },
    cost: { type: 'object', required: ['min', 'max'], properties: { min: num, max: num }, additionalProperties: false },
    gain: { type: 'object', required: ['whp', 'basis'], properties: { whp: num, basis: str }, additionalProperties: false },
  }),
  competitors: rec({ id: str, name: str, power: nul(str), quarterMile: nul(str), lap: nul(str), price: nul(str), verdict: str }, {
    sheet: rec({ model: str, hp: nul(num), torque: nul(num), weightLb: nul(num), zeroTo60: nul(num), zeroTo60By: nul(str), quarterMile: nul(str), priceUsd: nul(num) }, { hidden: bool }),
  }),
  communities: rec({ id: str, name: str, description: str }),
  media: rec({ id: str, youtubeId: { type: 'string', pattern: '^[\\w-]{11}$' }, title: str, credit: str,
    category: en('Official', 'Review', 'Comparison', 'Track', 'Drag / Dyno', 'Onboard', 'Stock sound', 'Aftermarket sound') }, { modified: bool }),
  photos: rec({ id: str, title: str, author: str, license: str, licenseUrl: https, thumb: { type: 'string', pattern: '^https://upload\\.wikimedia\\.org/\\S+$' } }),
  audio: rec({ id: str, title: str, author: str, license: str, licenseUrl: https, freesoundId: { type: 'string', pattern: '^\\d+$' } }),
  dynoBaselines: rec({ id: str, label: str, year: nul(year), whp: num, wtq: nul(num), dyno: en('dynojet', 'mustang', 'hub', 'other'),
    correction: en('sae', 'std', 'uncorrected', 'unknown'), fuel: nul(str), date: nul(date) }, { context: str }),
  partNumbers: rec({ id: str, number: str, brand: str, description: str, category: en('Filter', 'Fluid', 'Ignition', 'Fluid spec', 'Performance part'),
    kind: en('part', 'spec', 'avoid'), maintenanceIds: arr(str), reminderIds: arr(str) }),
  guides: rec({ id: str, title: str, summary: str, status: en('ready', 'planned'), appliesTo: str, tools: arr(str),
    warnings: arr(rec({ text: str })), steps: arr(rec({ text: str }, { factId: str })), partIds: arr(str) }),
  auctionResults: rec({ id: str, date: nul(date), venue: nul(str), year, mileage: nul(num), price: nul(num),
    outcome: en('sold', 'offer', 'no-sale'), cftp: nul(bool), heritage: nul(bool), description: str }, {
    localPrice: { type: 'object', required: ['amount', 'currency'], properties: { amount: num, currency: en('GBP', 'EUR', 'CAD') }, additionalProperties: false },
    outlier: str, conflicts: arr({ $ref: '#/$defs/stringValue' }, 1),
  }),
  marketStats: sv(num, { id: str, label: str, year, kind: en('yearly-median', 'median', 'estimate') },
    { period: str, sampleSize: nul(num), conflicts: arr({ $ref: '#/$defs/numberValue' }, 1) }),
  editions: rec({ id: str, name: str, years: str, modelYears: arr(year), hpClaim: nul(str), price: nul(num), production: nul(str), content: nul(str),
    streetLegal: nul(bool), research }, { priceNote: str, upfitPrice: nul(num), productionConflicts: arr({ $ref: '#/$defs/stringValue' }, 1) }),
  fpCatalog: rec({ id: str, number: { type: 'string', pattern: '^M-[\\w-]+$' }, name: str, msrp: nul(num), priceAsOf: nul(date),
    emissions: en('carb-eo', '50-state-legal', 'not-legal-for-road', null), fitmentYears: arr(year), fitmentExplicit: bool,
    category: en('Body & aero', 'Engine', 'Fuel & cooling', 'Driveline', 'Appearance'), research }),
  events: rec({ id: str, kind: en('program', 'convention', 'auction'), name: str, date: nul(date), location: nul(str), research }, { dateText: str, cost: nul(str) }),
  milestones: rec({ id: str, date: nul(date), title: str, research }, { placement: nul(str) }),
  notes: rec({ text: str }),
};

const DEFS: Record<string, JsonSchema> = {
  source: https,
  confidence: en(...CONFIDENCE),
  conflict: sv(strnum),
  numberValue: sv(num),
  stringValue: sv(str),
};

/** One JSON Schema per collection (an array of records); each is self-contained (shared `$defs` copied in). */
export const SCHEMAS: Record<string, JsonSchema> = Object.fromEntries(Object.entries(ITEMS).map(([name, items]) => {
  return [name, {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: `https://github.com/Catsasstrophy-Warez/LetsFNgo/schemas/${name}.schema.json`,
    title: `GT500 Companion — ${name}`,
    description: `Array of ${name} records (src/data). Every record cites an https source and a confidence level; unknowns are null with a note.`,
    type: 'array',
    items,
    $defs: DEFS,
  }];
}));

export interface Issue { collection: string; path: string; message: string }

const typeOf = (v: unknown) => (v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v);

/** Validate `v` against the JSON Schema subset used above. Returns error strings ("path: message"). */
export function validateSchema(schema: JsonSchema, v: unknown, root: JsonSchema = schema, path = '$'): string[] {
  if (typeof schema.$ref === 'string') {
    const m = /^#\/\$defs\/(\w+)$/.exec(schema.$ref);
    const target = m ? (root.$defs as Record<string, JsonSchema> | undefined)?.[m[1]] : undefined;
    return target ? validateSchema(target, v, root, path) : [`${path}: unresolved $ref ${schema.$ref}`];
  }
  if (Array.isArray(schema.anyOf)) {
    return (schema.anyOf as JsonSchema[]).some((s) => validateSchema(s, v, root, path).length === 0) ? [] : [`${path}: does not match any allowed shape (got ${typeOf(v)})`];
  }
  if ('const' in schema && v !== schema.const) return [`${path}: must be ${JSON.stringify(schema.const)}`];
  if (Array.isArray(schema.enum) && !schema.enum.includes(v as never)) return [`${path}: ${JSON.stringify(v)} is not one of ${JSON.stringify(schema.enum)}`];
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const t = typeOf(v);
    if (!types.includes(t) && !(t === 'number' && types.includes('integer') && Number.isInteger(v))) return [`${path}: expected ${types.join('|')}, got ${t}`];
    if (t === 'number' && !Number.isFinite(v)) return [`${path}: must be a finite number`];
  }
  const errs: string[] = [];
  if (typeof v === 'string') {
    if (typeof schema.minLength === 'number' && v.trim().length < schema.minLength) errs.push(`${path}: must not be empty`);
    if (typeof schema.pattern === 'string' && !new RegExp(schema.pattern).test(v)) errs.push(`${path}: ${JSON.stringify(v)} does not match ${schema.pattern}`);
  }
  if (Array.isArray(v)) {
    if (typeof schema.minItems === 'number' && v.length < schema.minItems) errs.push(`${path}: needs at least ${schema.minItems} item(s)`);
    if (schema.items) v.forEach((x, i) => errs.push(...validateSchema(schema.items as JsonSchema, x, root, `${path}[${i}]`)));
  }
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    const o = v as Record<string, unknown>;
    const props = (schema.properties ?? {}) as Record<string, JsonSchema>;
    for (const k of (schema.required ?? []) as string[]) if (!(k in o)) errs.push(`${path}: missing required field "${k}"`);
    for (const [k, x] of Object.entries(o)) {
      if (props[k]) errs.push(...validateSchema(props[k], x, root, `${path}.${k}`));
      else if (schema.additionalProperties === false) errs.push(`${path}: unknown field "${k}" (add it to src/lib/dataSchema.ts)`);
    }
  }
  return errs;
}

const CONFLICT_KEYS = ['conflicts', 'priceConflicts', 'productionConflicts'] as const;
const LEVEL: Record<string, string> = { high: 'confirmed', medium: 'reported', low: 'unverified' };

/** Walk a record and call `f` for every nested object with a source (path, object). */
function eachSourced(v: unknown, path: string, f: (p: string, o: Record<string, unknown>) => void) {
  if (Array.isArray(v)) v.forEach((x, i) => eachSourced(x, `${path}[${i}]`, f));
  else if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    if ('source' in o || 'confidence' in o) f(path, o);
    for (const [k, x] of Object.entries(o)) eachSourced(x, `${path}.${k}`, f);
  }
}

/**
 * Every contribution rule: schema shape, https source, confidence enum, null values explained by a note,
 * research level matching its badge, unique ids / no duplicate records, and well-formed conflicts.
 */
export function checkCollections(collections: Record<string, Sourced[]>): Issue[] {
  const issues: Issue[] = [];
  for (const [name, recs] of Object.entries(collections)) {
    const push = (path: string, message: string) => issues.push({ collection: name, path, message });
    const schema = SCHEMAS[name];
    if (!schema) { push('$', 'no JSON Schema for this collection (add it to src/lib/dataSchema.ts)'); continue; }
    if (!recs.length) push('$', 'collection is empty');
    for (const e of validateSchema(schema, recs)) { const i = e.indexOf(': '); push(e.slice(0, i), e.slice(i + 2)); }
    const ids = new Map<string, number>();
    const seen = new Map<string, number>();
    recs.forEach((r, i) => {
      const o = r as unknown as Record<string, unknown>;
      const at = `$[${i}]`;
      if (typeof o.id === 'string') { if (ids.has(o.id)) push(at, `duplicate id "${o.id}" (also at $[${ids.get(o.id)}])`); else ids.set(o.id, i); }
      const key = JSON.stringify({ ...o, id: undefined });
      if (seen.has(key)) push(at, `duplicate record (same content as $[${seen.get(key)}])`); else seen.set(key, i);
      if (typeof o.research === 'string' && LEVEL[o.research] && o.confidence !== LEVEL[o.research]) push(`${at}.confidence`, `research level "${o.research}" must be badged "${LEVEL[o.research]}"`);
      eachSourced(o, at, (p, s) => {
        if (typeof s.source !== 'string' || !/^https:\/\/\S+$/.test(s.source)) push(`${p}.source`, 'source must be an https URL');
        if (!CONFIDENCE.includes(s.confidence as string)) push(`${p}.confidence`, `confidence must be one of ${CONFIDENCE.join(', ')}`);
        if ('value' in s && s.value === null && !(typeof s.note === 'string' && s.note.trim())) push(`${p}.note`, 'a null value needs a note explaining the gap');
      });
      for (const k of CONFLICT_KEYS) {
        const list = o[k];
        if (list === undefined) continue;
        if (!Array.isArray(list) || list.length === 0) { push(`${at}.${k}`, 'conflicts must be a non-empty list of sourced values'); continue; }
        const own = k === 'priceConflicts' ? (o.price as { value?: unknown } | undefined)?.value : k === 'productionConflicts' ? o.production : o.value;
        const vals = new Set([own, ...list.map((c) => (c as { value?: unknown }).value)].filter((x) => x !== undefined && x !== null).map((x) => String(x)));
        if (vals.size < 2) push(`${at}.${k}`, 'a conflict needs at least two different sourced values');
        const pairs = list.map((c) => JSON.stringify([(c as { value?: unknown }).value, (c as { source?: unknown }).source, (c as { context?: unknown }).context]));
        if (new Set(pairs).size !== pairs.length) push(`${at}.${k}`, 'the same value + source + context is listed twice');
      }
    });
  }
  return issues;
}
