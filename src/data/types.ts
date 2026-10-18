/** How well a fact is supported by its cited source. */
export type Confidence = 'confirmed' | 'reported' | 'unverified';

/** Every fact record in the app carries a source URL and a confidence level. */
export interface Sourced {
  source: string;
  confidence: Confidence;
  note?: string;
  /** The original URL when `source` points at a Wayback Machine snapshot of a dead page. */
  originalUrl?: string;
}

export type ModelYear = 2020 | 2021 | 2022;

/** A single sourced value. `value` is null when the figure is unknown — never invent it. */
export interface SourcedValue<T = number | string> extends Sourced {
  value: T | null;
  context?: string;
}

/** A spec line. When sources disagree, `conflicts` lists every sourced value. */
export interface SpecFact extends SourcedValue {
  id: string;
  system: SpecSystem;
  label: string;
  unit?: string;
  conflicts?: SourcedValue[];
}

export type SpecSystem =
  | 'Engine'
  | 'Drivetrain'
  | 'Chassis & Brakes'
  | 'Wheels & Tires'
  | 'Dimensions & Weight'
  | 'Fuel & Economy'
  | 'Features';

export interface ModelYearEntry extends Sourced {
  id: string;
  year: ModelYear | null;
  name: string;
  builder: 'Ford' | 'Shelby American';
  summary: string;
  changes: string[];
}

export interface PaintColor extends Sourced {
  id: string;
  name: string;
  /** Ford paint code; null where no source was found. */
  code: string | null;
  /** Approximate display swatch only — not an official color value. */
  swatch: string;
  years: ModelYear[];
  yearsNote?: string;
}

export interface OptionPackage extends Sourced {
  id: string;
  name: string;
  years: ModelYear[];
  price: SourcedValue<number>;
  priceConflicts?: SourcedValue<number>[];
  contents: string[];
  contentsConfidence: Confidence;
}

export interface PriceRecord extends SourcedValue<number> {
  id: string;
  year: ModelYear;
  label: string;
  kind: 'msrp' | 'destination' | 'gas-guzzler' | 'delivered' | 'as-tested';
}

export interface MarketSale extends Sourced {
  id: string;
  date: string | null;
  venue: string;
  description: string;
  year: ModelYear;
  amount: number;
  outcome: 'sold' | 'high-bid' | 'asking';
}

export interface ProductionFact extends SourcedValue {
  id: string;
  conflicts?: SourcedValue[];
  label: string;
  scope: string;
}

export interface PerformanceRecord extends Sourced {
  id: string;
  category: 'acceleration' | 'quarter-mile' | 'lap' | 'drag-record';
  label: string;
  result: string;
  car: 'stock' | 'stock (CFTP)' | 'modified' | 'Shelby American';
  /** Date of the run/report where known, so records read as snapshots. */
  date: string | null;
}

export interface RecallIssue extends Sourced {
  id: string;
  title: string;
  kind: 'recall' | 'nhtsa-recall' | 'service-action' | 'tsb' | 'complaint' | 'owner-report' | 'vendor-claim';
  years?: string;
  campaign: string | null;
  summary: string;
  /** Whether the campaign covers the GT500: yes, likely (no exclusion, full build span), no, vin (depends on VIN), or unknown (sources disagree on scope). */
  appliesToGT500?: 'yes' | 'likely' | 'no' | 'vin' | 'unknown';
  /** What the recall documents say about scope. */
  evidence?: string;
  /** Affected build dates where the documents give them. */
  buildWindow?: string | null;
}

export interface MaintenanceItem extends SourcedValue {
  id: string;
  item: string;
  group: 'Fluids' | 'Service' | 'Warranty' | 'Ownership';
  unit?: string;
  conflicts?: SourcedValue[];
  warning?: string;
}

export interface ModStage extends Sourced {
  id: string;
  stage: string;
  parts: string;
  result: string;
  status?: 'excluded';
  /** Parts price range in USD, only where the cited source lists one. */
  cost?: { min: number; max: number };
  /** Wheel-horsepower gain over stock, only where the cited source states it or both figures on the same dyno. */
  gain?: { whp: number; basis: string };
}

export interface Competitor extends Sourced {
  id: string;
  name: string;
  power: string | null;
  quarterMile: string | null;
  lap: string | null;
  price: string | null;
  verdict: string;
  /** Round-3 spec-sheet figures, each with its own source. */
  sheet?: CompetitorSheet;
  /** Base prices by model year (round 11), each with its own source. `context` names the exact trim / basis. */
  prices?: CompetitorPrice[];
}

/** One sourced competitor price for a model year and trim (`context` is required). */
export interface CompetitorPrice extends SourcedValue<number> {
  modelYear: number;
  destinationIncluded: boolean | null;
  context: string;
}

/** A base MSRP with its model year and whether destination is included (null when the source does not say). */
export interface MsrpValue extends SourcedValue<number> {
  modelYear: number;
  destinationIncluded: boolean | null;
  conflicts?: SourcedValue<number>[];
}

export interface CompetitorSheet extends Sourced {
  /** Exact model the figures describe (may differ from the comparison-test car). */
  model: string;
  hp: number | null;
  torque: number | null;
  weightLb: number | null;
  zeroTo60: number | null;
  /** Who produced the 0–60 figure (claim, magazine, database). */
  zeroTo60By: string | null;
  quarterMile: string | null;
  priceUsd: number | null;
  /** Base MSRP from its own source (model year may differ from the figures above). */
  msrp?: MsrpValue;
  /** Low-quality or database-only rows: kept for transparency, hidden by default. */
  hidden?: boolean;
}

export interface Community extends Sourced {
  id: string;
  name: string;
  description: string;
}

export interface MediaItem extends Sourced {
  id: string;
  youtubeId: string;
  title: string;
  credit: string;
  category: 'Official' | 'Review' | 'Comparison' | 'Track' | 'Drag / Dyno' | 'Onboard' | 'Stock sound' | 'Aftermarket sound';
  modified?: boolean;
}

export interface VinPosition extends Sourced {
  positions: string;
  meaning: string;
}

export interface CommonsPhoto extends Sourced {
  id: string;
  title: string;
  author: string;
  license: string;
  licenseUrl: string;
  /** Hotlinked thumbnail on upload.wikimedia.org. */
  thumb: string;
}

export interface AudioClip extends Sourced {
  id: string;
  title: string;
  author: string;
  license: string;
  licenseUrl: string;
  freesoundId: string;
}

/** A sourced stock dyno baseline (wheel figures) for comparing your own pulls. */
export interface DynoBaseline extends Sourced {
  id: string;
  label: string;
  /** Peak rpm or gear details where the source gives them. */
  context?: string;
  year: ModelYear | null;
  whp: number;
  wtq: number | null;
  dyno: 'dynojet' | 'mustang' | 'hub' | 'other';
  correction: 'sae' | 'std' | 'uncorrected' | 'unknown';
  fuel: string | null;
  date: string | null;
}

/** A retail price for a part, seen on a given date. Shown on the Cost page as a sourced price; never a default. */
export interface PartPrice extends SourcedValue<number> {
  /**
   * What one `value` buys: one part, one US quart of a fluid, or one seller listing whose pack size is unclear
   * ('listing': never turned into a per-part or per-quart price; the context says what is unclear).
   */
  per: 'each' | 'quart' | 'listing';
  /** YYYY-MM-DD the price was seen. */
  dateSeen: string;
  /** Other sourced prices (other sellers / snapshots). */
  conflicts?: SourcedValue<number>[];
}

/** A part number or fluid spec, only where a cited source names it. Linked back to maintenance facts and Garage reminders. */
export interface PartNumber extends Sourced {
  id: string;
  /** The number exactly as the source prints it (e.g. "FL-2087"). */
  number: string;
  brand: string;
  description: string;
  category: 'Filter' | 'Fluid' | 'Ignition' | 'Fluid spec' | 'Performance part' | 'Brake pad (aftermarket)';
  /** 'avoid' marks a number a source says is wrong for this car. */
  kind: 'part' | 'spec' | 'avoid';
  /** Related `maintenance` fact ids. */
  maintenanceIds: string[];
  /** Default Garage reminder ids this part is used for. */
  reminderIds: string[];
  /** A sourced retail price (research round 15+), only where a source gives one. */
  price?: PartPrice;
}

/** One step of a how-to guide. Every step carries its own source and confidence. */
export interface GuideStep extends Sourced {
  text: string;
  /** Related maintenance fact id, if the step restates one. */
  factId?: string;
}

export interface GuideWarning extends Sourced { text: string }

/**
 * A step-by-step guide. `status: 'planned'` is an empty slot: the topic is wanted but no source backs a procedure
 * yet, so it has no steps. A guide's own confidence is never higher than its weakest step.
 */
export interface Guide extends Sourced {
  id: string;
  title: string;
  summary: string;
  status: 'ready' | 'planned';
  appliesTo: string;
  /** Tools a source lists. Empty means none are sourced — never guessed. */
  tools: string[];
  warnings: GuideWarning[];
  steps: GuideStep[];
  /** Related `partNumbers` ids. */
  partIds: string[];
}

/**
 * One public auction / marketplace result. `price` is USD and null when no USD figure was published
 * (a foreign-currency conversion is kept in `localPrice`, never converted). `outlier` explains why a result
 * is excluded from medians by default; `conflicts` lists every sourced value when sources disagree.
 */
export interface AuctionResult extends Sourced {
  id: string;
  /** YYYY-MM-DD, or YYYY-MM when only the month is known; null when unknown. */
  date: string | null;
  venue: string | null;
  year: ModelYear;
  mileage: number | null;
  price: number | null;
  localPrice?: { amount: number; currency: 'GBP' | 'EUR' | 'CAD' };
  outcome: 'sold' | 'offer' | 'no-sale';
  /** null = not stated by the source. */
  cftp: boolean | null;
  heritage: boolean | null;
  outlier?: string;
  conflicts?: SourcedValue<string>[];
  description: string;
}

/** A published market statistic (median, valuation) from one source. */
export interface MarketStat extends SourcedValue<number> {
  id: string;
  label: string;
  /** Model year the figure covers. */
  year: ModelYear;
  kind: 'yearly-median' | 'median' | 'estimate';
  period?: string;
  sampleSize?: number | null;
  conflicts?: SourcedValue<number>[];
}

/** The research notes' own confidence scale (round 8+), kept verbatim next to the app's badge level. */
export type ResearchLevel = 'high' | 'medium' | 'low';
/** Badge level for a research level: high → confirmed, medium → reported, low → unverified. */
export const levelToConfidence = (l: ResearchLevel): Confidence => (l === 'high' ? 'confirmed' : l === 'medium' ? 'reported' : 'unverified');

/**
 * A Shelby American post-title edition built on the 2020–22 GT500. Every unknown is null — never estimated.
 * `price` is the new-car or package price as the source states it (see `priceNote`); `upfitPrice` is the price to
 * convert an existing car, where one is published.
 */
export interface ShelbyEdition extends Sourced {
  id: string;
  name: string;
  /** Years as the source words them (e.g. "2022 (upfit available for 2020-2021 cars)"). */
  years: string;
  /** Donor/base model years the edition applies to, for filtering. */
  modelYears: ModelYear[];
  hpClaim: string | null;
  price: number | null;
  priceNote?: string;
  upfitPrice?: number | null;
  production: string | null;
  /** Every sourced value when sources disagree on production. */
  productionConflicts?: SourcedValue<string>[];
  content: string | null;
  streetLegal: boolean | null;
  research: ResearchLevel;
}

/** Emissions/legal status as Ford Performance labels a part; null when the catalog does not say. */
export type EmissionsStatus = 'carb-eo' | '50-state-legal' | 'not-legal-for-road' | null;

/** A Ford Performance catalog item (M-number). MSRP is the price on the fetch date, not a period price. */
export interface FpCatalogItem extends Sourced {
  id: string;
  /** M-number exactly as printed, e.g. "M-6766-A52". */
  number: string;
  name: string;
  msrp: number | null;
  /** YYYY-MM-DD the price was read. */
  priceAsOf: string | null;
  emissions: EmissionsStatus;
  /** GT500 model years the part fits. */
  fitmentYears: ModelYear[];
  /** false = fitment inferred from the part name, not listed for the 2020–22 GT500 by the catalog. */
  fitmentExplicit: boolean;
  category: 'Body & aero' | 'Engine' | 'Fuel & cooling' | 'Driveline' | 'Appearance';
  research: ResearchLevel;
}

/** An owner event, program or notable auction tied to the 2020–22 GT500. */
export interface HistoryEvent extends Sourced {
  id: string;
  kind: 'program' | 'convention' | 'auction';
  name: string;
  /** YYYY, YYYY-MM or YYYY-MM-DD; null when unknown. `dateText` keeps the source's wording. */
  date: string | null;
  dateText?: string;
  location: string | null;
  cost?: string | null;
  research: ResearchLevel;
}

/** A media/press milestone (reveal, award). `placement` is null when the final result is unknown. */
export interface Milestone extends Sourced {
  id: string;
  date: string | null;
  title: string;
  placement?: string | null;
  research: ResearchLevel;
}

/** A point on a circuit, WGS84 decimal degrees. */
export interface GeoPoint { lat: number; lon: number }
/** A timing line between two points (start/finish or a sector split). */
export interface GeoLine { a: GeoPoint; b: GeoPoint }

/**
 * A circuit or drag strip for the GPS lap timer. `facility` is the facility's map coordinate (a Wikipedia article
 * point, precision roughly 1 m–1 km) — NOT a timing line. It is only used to suggest the nearest track; the owner
 * always sets the start/finish line on-site. `startFinish` stays null until a sourced line exists.
 */
export interface TrackDef extends Sourced {
  id: string;
  name: string;
  kind: 'road course' | 'drag strip' | 'oval + road course' | 'road course + drag strip' | 'oval + road course + drag strip';
  configuration: string;
  city: string;
  state: string;
  /** Facility point (not a start/finish line), or null when not sourced. */
  facility: GeoPoint | null;
  /** Start/finish line, only from a source that publishes one. Never derived from `facility`. */
  startFinish: GeoLine | null;
  direction?: 1 | -1;
  /** Sector split lines in lap order. */
  sectors: GeoLine[];
  /** Lap / strip length in miles, or null. */
  lengthMi: number | null;
  /** Typical drive-by / static noise limit in dB, only where a source states one (research round 16). Event-day variants go in `conflicts`. */
  noiseLimit?: NoiseLimit;
}

/** A track noise limit in dB. `context` names how it applies; other sourced limits (event days) are kept in `conflicts`. */
export interface NoiseLimit extends SourcedValue<number> {
  conflicts?: SourcedValue<number>[];
}

/**
 * A sourced start/finish timing line for one track configuration, linked to `tracks` by `trackId`. Only from a source
 * that publishes the line (track map / timing documentation, or an OpenStreetMap way). Never derived from `facility`.
 */
export interface StartFinishLine extends Sourced {
  id: string;
  /** `TrackDef.id` this line belongs to. */
  trackId: string;
  /** Named configuration (e.g. "Full Course"). */
  configuration: string;
  a: GeoPoint;
  b: GeoPoint;
  /** Counted crossing direction (+1 / −1 as in the lap timer); absent = either direction, the first crossing sets it. */
  direction?: 1 | -1;
  /** Sector split lines in lap order (may be empty). */
  sectors: GeoLine[];
}
