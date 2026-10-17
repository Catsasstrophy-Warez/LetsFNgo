import { test, expect, type Page } from '@playwright/test';

/**
 * Visual regression: key pages in both themes at phone size, compared with committed baselines in
 * e2e/__screenshots__/visual.spec.ts/. Only the viewport is captured (not the full page) and the clock is fixed,
 * so baselines stay stable. After an intended UI change: npm run build && npm run e2e:update-visual, review the
 * PNG diffs, and commit them.
 */
const PAGES = ['/', '/specs', '/colors', '/performance', '/market', '/coverage', '/editions', '/history', '/garage', '/settings'];

async function seed(page: Page, theme: 'dark' | 'light') {
  await page.clock.setFixedTime(new Date('2026-06-01T12:00:00Z'));
  await page.emulateMedia({ reducedMotion: 'reduce', colorScheme: theme });
  await page.addInitScript((t) => {
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t, lang: 'en' }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.install.v1', JSON.stringify({ dismissed: '2026-06-01' }));
  }, theme);
}

for (const theme of ['dark', 'light'] as const) {
  for (const route of PAGES) {
    test(`visual ${theme} ${route}`, async ({ page }, info) => {
      test.skip(info.project.name !== 'mobile', 'baselines are phone-sized');
      await seed(page, theme);
      await page.goto(`./#${route}`);
      await expect(page.locator('main h1').first()).toBeVisible();
      await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
      await page.evaluate(() => document.fonts.ready);
      await expect(page).toHaveScreenshot(`${theme}${route === '/' ? '-home' : route.replace(/\//g, '-')}.png`);
    });
  }
}
