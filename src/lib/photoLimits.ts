/** Photo limits and ids shared by the photo store and backup validation (kept tiny: validation is in the main chunk). */
export type PhotoKind = 'service' | 'mod' | 'track';
export const PHOTO_KINDS: PhotoKind[] = ['service', 'mod', 'track'];
/** Longest side of a stored photo (px). */
export const MAX_DIM = 1600;
/** Largest stored (compressed) photo. */
export const MAX_PHOTO_BYTES = 1_500_000;
/** Most photos per entry. */
export const MAX_PER_OWNER = 6;
/** Most photos on this device. */
export const MAX_PHOTOS = 200;
/** Most bytes of photos on this device (thumbnails included). */
export const MAX_TOTAL_BYTES = 45 * 1024 * 1024;
export const OWNER_ID_RE = /^[A-Za-z0-9_-]{1,40}$/;
export const PHOTO_ID_RE = /^p[A-Za-z0-9_-]{4,40}$/;
/** Photo as stored in a backup: the JPEG as base64 (the thumbnail is rebuilt on restore). */
export interface PhotoBackup { id: string; kind: PhotoKind; ownerId: string; created: string; w: number; h: number; data: string }
