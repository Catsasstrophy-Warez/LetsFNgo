import { describe, expect, it } from 'vitest';
import { renderToString } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import App, { NAV } from '../src/App';

describe('every route renders without throwing', () => {
  for (const path of [...NAV.map((n) => n.to), '/search']) {
    it(path, () => {
      const html = renderToString(<MemoryRouter initialEntries={[path]}><App /></MemoryRouter>);
      expect(html).toContain('Not affiliated');
    });
  }
});
