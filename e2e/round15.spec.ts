import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

async function seed(page: Page, lang: 'en' | 'es' = 'en') {
  await page.addInitScript((l) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: 'dark', lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.install.v1', JSON.stringify({ dismissed: '2026-06-01' }));
  }, lang);
}
const serious = async (page: Page) => (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id);
const cspErrors = (page: Page) => { const errs: string[] = []; page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy/i.test(m.text())) errs.push(m.text()); }); return errs; };

test("Buyer's guide: VIN recalls, price position, checklist ticks persist", async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page);
  await page.goto('./#/buy');
  await expect(page.getByRole('heading', { level: 1, name: "Buyer's Guide" })).toBeVisible();

  await page.getByLabel('Enter a 17-character VIN').fill('1FA6P8SJ1L5504855');
  await expect(page.getByText('Model year 2020 (from VIN position 10).')).toBeVisible();
  await expect(page.getByRole('heading', { name: /Recalls and campaigns to ask about/ })).toBeVisible();
  await expect(page.getByText('20V573000').first()).toBeVisible();

  await page.getByLabel('Asking price (USD)').fill('90000');
  await page.locator('section[aria-labelledby=buy-price]').getByLabel('Model year').selectOption('2020');
  await page.getByLabel('Odometer (miles, optional)').fill('3000');
  await expect(page.getByText(/^\$90,000: \d+ of \d+ sourced 2020 sales were lower/)).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Closest sourced sales by mileage' })).toBeVisible();

  await page.getByRole('button', { name: 'Use 2020 for the checklist' }).click();
  const first = page.locator('section[aria-labelledby=buy-list] input[type=checkbox]').first();
  await first.check();
  await expect(page.getByText(/^1 of \d+ checked$/)).toBeVisible();
  expect(await serious(page)).toEqual([]);

  await page.reload();
  await expect(page.getByText(/^1 of \d+ checked$/)).toBeVisible();
  const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('gt500.buyer.v1') ?? '{}'));
  expect(stored.checked).toHaveLength(1);
  expect(csp).toEqual([]);
});
