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

test('Build & sticker: totals, unpriced lines, year filter, persistence', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page);
  await page.goto('./#/build-sheet');
  await expect(page.getByRole('heading', { level: 1, name: 'Build & Sticker' })).toBeVisible();
  const total = page.locator('tfoot [role=status]');
  await expect(total).toContainText('$73,995');

  await page.getByLabel('Carbon Fiber Track Pack (CFTP)').check();
  await expect(total).toContainText('$92,495');
  await expect(page.getByText('Other sourced values:').first()).toBeVisible();
  expect(await serious(page)).toEqual([]);

  await page.getByLabel('Model year').selectOption('2021');
  await expect(page.getByLabel('Carbon Fiber Handling Package')).toBeVisible();
  await expect(total).toContainText('at least $89,995');
  await expect(total).toContainText('1 line without a sourced price');

  await page.reload();
  await expect(page.getByLabel('Model year')).toHaveValue('2021');
  await expect(page.getByLabel('Carbon Fiber Track Pack (CFTP)')).toBeChecked();
  expect(csp).toEqual([]);
});

test('Build & sticker in Spanish, reachable from the menu', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page, 'es');
  await page.goto('./#/build-sheet');
  await expect(page.getByRole('heading', { level: 1, name: 'Configuración y etiqueta' })).toBeVisible();
  await expect(page.getByRole('rowheader', { name: 'MSRP base' })).toBeVisible();
  expect(await serious(page)).toEqual([]);
  expect(csp).toEqual([]);
});
