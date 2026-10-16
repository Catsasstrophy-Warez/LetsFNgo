/** How well a fact is supported by its cited source. */
export type Confidence = 'confirmed' | 'reported' | 'unverified';

/** Every fact record in the app carries a source URL and a confidence level. */
export interface Sourced {
  source: string;
  confidence: Confidence;
  note?: string;
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
