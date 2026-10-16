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
  kind: 'recall' | 'service-action' | 'tsb' | 'owner-report' | 'vendor-claim';
  campaign: string | null;
  summary: string;
}

export interface MaintenanceItem extends SourcedValue {
  id: string;
  item: string;
}

export interface ModStage extends Sourced {
  id: string;
  stage: string;
  parts: string;
  result: string;
  status?: 'excluded';
}

export interface Competitor extends Sourced {
  id: string;
  name: string;
  power: string | null;
  quarterMile: string | null;
  lap: string | null;
  price: string | null;
  verdict: string;
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
  category: 'Official' | 'Review' | 'Comparison' | 'Track' | 'Drag / Dyno' | 'Stock sound' | 'Aftermarket sound';
  modified?: boolean;
}

export interface VinPosition extends Sourced {
  positions: string;
  meaning: string;
}
