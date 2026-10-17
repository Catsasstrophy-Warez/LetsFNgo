import type { StartFinishLine } from './types';

/**
 * Sourced start/finish lines (one record per track configuration), linked to `tracks` by `trackId`. Empty until a
 * line is sourced: a track map or timing document, or an OpenStreetMap way/node (credited "© OpenStreetMap
 * contributors"). See CONTRIBUTING.md → "Track start/finish lines". The lap timer offers "Use sourced line" only
 * when a record exists for the chosen track and configuration.
 */
export const startFinishLines: StartFinishLine[] = [];
