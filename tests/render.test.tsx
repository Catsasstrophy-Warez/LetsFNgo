import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router';
import App, { NAV, PAGES } from '../src/App';

describe('every route renders without throwing', () => {
  for (const path of [...NAV.map((n) => n.to), '/search']) {
    it(path, () => {
      const html = renderToString(<MemoryRouter initialEntries={[path]}><App /></MemoryRouter>);
      expect(html).toContain('Not affiliated');
    });
  }
});

describe('every lazy page renders', () => {
  for (const [name, load] of Object.entries(PAGES)) {
    it(name, async () => {
      const { default: Page } = await load();
      const html = renderToString(<MemoryRouter><Page /></MemoryRouter>);
      expect(html.length).toBeGreaterThan(50);
    });
  }
});
