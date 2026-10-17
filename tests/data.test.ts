import { describe, expect, it } from 'vitest';
import { collections, collectSourced, allSourceUrls } from '../src/data';
import { search } from '../src/lib/search';
import { MAY_BE_EMPTY } from '../src/lib/dataSchema';

const CONF = ['confirmed', 'reported', 'unverified'];

describe('data integrity', () => {
  it('every top-level record has source + confidence', () => {
    for (const [name, recs] of Object.entries(collections)) {
      if (!MAY_BE_EMPTY.has(name)) expect(recs.length, name).toBeGreaterThan(0);
      for (const r of recs) {
        expect(typeof r.source, `${name}: ${JSON.stringify(r).slice(0, 80)}`).toBe('string');
        expect(CONF, name).toContain(r.confidence);
      }
    }
  });
  it('every nested sourced value has a valid http(s) source URL and confidence', () => {
    for (const s of collectSourced(Object.values(collections))) {
      expect(s.source).toMatch(/^https?:\/\/\S+$/);
      expect(CONF).toContain(s.confidence);
    }
  });
  it('null values carry a note explaining the gap', () => {
    for (const s of collectSourced(Object.values(collections))) {
      const o = s as unknown as Record<string, unknown>;
      if ('value' in o && o.value === null) expect(o.note, JSON.stringify(o)).toBeTruthy();
    }
  });
  it('ids are unique within each collection', () => {
    for (const [name, recs] of Object.entries(collections)) {
      const ids = recs.map((r) => (r as unknown as { id?: string }).id).filter(Boolean);
      expect(new Set(ids).size, name).toBe(ids.length);
    }
  });
  it('curb weight is modeled as a conflict with multiple sourced values', () => {
    const cw = collections.specs.find((s) => (s as unknown as { id: string }).id === 'curb-weight') as unknown as { conflicts: unknown[] };
    expect(cw.conflicts.length).toBeGreaterThanOrEqual(3);
  });
  it('youtube embeds use valid IDs', () => {
    for (const m of collections.media as unknown as { youtubeId: string }[]) expect(m.youtubeId).toMatch(/^[\w-]{11}$/);
  });
  it('has a source list and search works', () => {
    expect(allSourceUrls().length).toBeGreaterThan(50);
    expect(search('carbonized').length).toBeGreaterThan(0);
  });
});
