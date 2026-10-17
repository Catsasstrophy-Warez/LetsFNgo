import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import { SettingsContext } from '../src/components/SettingsContext';
import { DEFAULT_SETTINGS } from '../src/lib/units';
import { startFinishLines } from '../src/data/startFinishLines';
import { tracks } from '../src/data/tracks';
import { checkCollections } from '../src/lib/dataSchema';
import { isOsmSource, linesForTrack, segmentIntersect, projector } from '../src/lib/lapTimer';
import { SourcedLinePicker } from '../src/components/SourcedLine';
import Sources from '../src/pages/Sources';
import Help from '../src/pages/Help';
import type { Sourced } from '../src/data/types';

const wrap = (el: JSX.Element) => renderToString(
  <SettingsContext.Provider value={{ settings: { ...DEFAULT_SETTINGS }, setSettings: () => undefined }}>
    <MemoryRouter>{el}</MemoryRouter>
  </SettingsContext.Provider>,
);
const COPY = 'https://www.openstreetmap.org/copyright';

describe('OpenStreetMap start/finish lines (ODbL)', () => {
  it('file carries the ODbL header', () => {
    const src = readFileSync('src/data/startFinishLines.ts', 'utf8');
    for (const s of ['© OpenStreetMap contributors', 'Open Database License (ODbL) 1.0', COPY, '2026-06-01', 'derived']) expect(src).toContain(s);
    expect(readFileSync('LICENSE-DATA-OSM.md', 'utf8')).toContain('ODbL');
    expect(readFileSync('README.md', 'utf8')).toMatch(/## Third-party data[\s\S]*ODbL[\s\S]*not affected/);
  });
  it('every entry is unverified, OSM-sourced, noted, valid and linked to a track', () => {
    const ids = new Set(tracks.map((t) => t.id));
    expect(new Set(startFinishLines.map((l) => l.id)).size).toBe(startFinishLines.length);
    for (const l of startFinishLines) {
      expect(l.confidence).toBe('unverified');
      expect(isOsmSource(l.source)).toBe(true);
      expect(l.source).toMatch(/^https:\/\/www\.openstreetmap\.org\/node\/\d+$/);
      expect(l.note).toMatch(/OSM node \d+/);
      expect(l.note).toMatch(/openstreetmap\.org\/way\/\d+/);
      expect(ids.has(l.trackId)).toBe(true);
    }
    expect(checkCollections({ tracks: tracks as unknown as Sourced[], startFinishLines: startFinishLines as unknown as Sourced[] })).toEqual([]);
  });
  it('COTA has both candidates and prefers the raceway=start-finish node; direction only where given', () => {
    const cota = linesForTrack(startFinishLines, 'circuit-of-the-americas');
    expect(cota).toHaveLength(2);
    for (const l of cota) expect(l.note).toMatch(/prefer the raceway=start-finish node 7909207460/);
    const chuck = linesForTrack(startFinishLines, 'chuckwalla-valley-raceway')[0];
    expect(chuck.direction).toBeUndefined();
    expect(startFinishLines.filter((l) => l.direction !== undefined)).toHaveLength(8);
  });
  it('direction +1 matches travel along the stated way bearing', () => {
    for (const l of startFinishLines.filter((x) => x.direction)) {
      const br = Number(/= ([\d.]+) deg/.exec(l.note ?? '')![1]) * Math.PI / 180;
      const p = projector(l.a);
      const mid = { x: p.toXY(l.b).x / 2, y: p.toXY(l.b).y / 2 };
      const hit = segmentIntersect({ x: mid.x - 20 * Math.sin(br), y: mid.y - 20 * Math.cos(br) }, { x: mid.x + 20 * Math.sin(br), y: mid.y + 20 * Math.cos(br) }, p.toXY(l.a), p.toXY(l.b));
      expect(hit?.side).toBe(l.direction);
    }
  });
  it('picker shows the derived/unverified warning and the OSM credit for every track', () => {
    for (const id of new Set(startFinishLines.map((l) => l.trackId))) {
      const html = wrap(<SourcedLinePicker trackId={id} lines={startFinishLines} onUse={() => undefined} />);
      expect(html).toContain('derived from map data and unverified');
      expect(html).toContain('Confirm it on-site');
      expect(html).toContain(`href="${COPY}"`);
      expect(html).toContain('© OpenStreetMap contributors');
    }
  });
  it('Sources and Help show the OpenStreetMap credit', () => {
    for (const P of [Sources, Help]) {
      const html = wrap(<P />);
      expect(html).toContain('Third-party data');
      expect(html).toContain(`href="${COPY}"`);
    }
  });
});
