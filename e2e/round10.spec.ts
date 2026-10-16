import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync } from 'node:fs';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

async function seed(page: Page, lang: 'en' | 'es' = 'en', theme: 'dark' | 'light' = 'dark') {
  await page.addInitScript(([l, t]) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t, lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
  }, [lang, theme]);
}
const goto = async (page: Page, route: string) => { await page.goto(`./#${route}`); await expect(page.locator('main h1').first()).toBeVisible(); };
const serious = async (page: Page) => (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id);

test('coverage dashboard: totals, gap links go to the page that shows the gap', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/coverage');
  await expect(page.getByRole('heading', { name: 'Data Coverage' })).toBeVisible();
  await expect(page.getByRole('heading', { name: /^Conflicts \(\d+\)/ })).toBeVisible();
  await shot(page, 'coverage', info.project.name);
  await page.getByLabel('Show gaps in').selectOption('auctionResults');
  const link = page.locator('.cov-group').first().getByRole('link').first();
  await link.click();
  await expect(page).toHaveURL(/#\/market/);
});

for (const theme of ['dark', 'light'] as const) {
  for (const lang of ['en', 'es'] as const) {
    test(`coverage axe clean (${theme}, ${lang})`, async ({ page }) => {
      await seed(page, lang, theme);
      await goto(page, '/coverage');
      await page.locator('.cov-group summary').first().click();
      expect(await serious(page)).toEqual([]);
    });
  }
}

test('chart points are keyboard-focusable with a tooltip; data table can be shown', async ({ page }, info) => {
  await seed(page);
  await page.addInitScript(() => localStorage.setItem('gt500.dyno.v1', JSON.stringify([{ id: 'd1', date: '2026-02-01', shop: 'Shop', dynoType: 'dynojet', correction: 'sae', whp: 690, wtq: 590, notes: '', mods: [],
    weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false },
    curve: [{ rpm: 3000, hp: 300, tq: 525 }, { rpm: 5000, hp: 520, tq: 560 }, { rpm: 7000, hp: 690, tq: 518 }] }])));
  await goto(page, '/dyno');
  const first = page.locator('.chart-pt[tabindex="0"]').first();
  await first.focus();
  await expect(page.locator('.chart-tip')).toBeVisible();
  await page.keyboard.press('ArrowRight');
  await expect(page.locator('.chart-pt:focus')).toHaveAttribute('data-pt', '1');
  await expect(page.locator('.chart-tip text')).toContainText('5000 rpm');
  await shot(page, 'chart-focus', info.project.name);
  const table = page.getByTestId('chart-table').first();
  await expect(table).toHaveClass(/sr-only/);
  await page.getByRole('button', { name: 'Show data table' }).first().click();
  await expect(table).not.toHaveClass(/sr-only/);
  expect(await serious(page)).toEqual([]);
});

test('reduced motion: drawer transition is disabled', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await seed(page);
  await goto(page, '/');
  const d = await page.locator('.drawer').evaluate((el) => parseFloat(getComputedStyle(el).transitionDuration));
  expect(d).toBeLessThan(0.01);
});

test('dev gallery is not routed in production builds', async ({ page }) => {
  await seed(page);
  await page.goto('./#/dev/gallery');
  await expect(page.locator('main h1').first()).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Component gallery' })).toHaveCount(0);
});

test('Parts: switching tabs keeps the search text', async ({ page }) => {
  await seed(page);
  await goto(page, '/parts');
  await page.getByRole('searchbox').fill('FL-');
  await page.getByRole('tab', { name: /Ford Performance/ }).click();
  await page.getByRole('tab', { name: /Fluids|Parts/ }).first().click();
  await expect(page.getByRole('searchbox')).toHaveValue('FL-');
});
