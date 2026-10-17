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
const trackSelect = (page: Page) => page.locator('select:has(option[value="weathertech-raceway-laguna-seca"])').first();
const cspErrors = (page: Page) => { const errs: string[] = []; page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy/i.test(m.text())) errs.push(m.text()); }); return errs; };

test('Track day planner and lap timer show the Laguna Seca noise limit', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page);
  await page.goto('./#/trackdays');
  await trackSelect(page).selectOption('weathertech-raceway-laguna-seca');
  await expect(page.getByTestId('noise-limit')).toContainText('Noise limit: 92 dB');
  await expect(page.getByTestId('noise-limit')).toContainText('103 dB');
  await trackSelect(page).selectOption('road-america');
  await expect(page.getByTestId('noise-limit')).toContainText('No sourced noise limit');
  expect(await serious(page)).toEqual([]);

  await page.goto('./#/laptimer');
  await trackSelect(page).selectOption('weathertech-raceway-laguna-seca');
  await expect(page.getByTestId('noise-limit')).toContainText('92 dB');
  expect(await serious(page)).toEqual([]);

  await page.goto('./#/track');
  await expect(page.getByText("Checked the track's noise limit for this event.")).toBeVisible();
  expect(csp).toEqual([]);
});

test('Tires and Parts show round 16 data (OEM fitment, aftermarket pads, DCT listing caveat)', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page);
  await page.goto('./#/tires');
  await expect(page.getByTestId('tire-oem')).toContainText('305/30ZR20 XL 103Y');
  await expect(page.getByTestId('tire-oem')).toContainText('315/30ZR20 XL 104Y');
  expect(await serious(page)).toEqual([]);
  await page.goto('./#/parts');
  await expect(page.getByText('HB928B.644')).toBeVisible();
  await expect(page.getByText('Aftermarket, not a Ford OEM part.').first()).toBeVisible();
  await expect(page.getByText(/\$117\.59 per listing, pack size unclear/)).toBeVisible();
  expect(await serious(page)).toEqual([]);
  expect(csp).toEqual([]);
});

test('Round 18 in Spanish', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page, 'es');
  await page.goto('./#/trackdays');
  await trackSelect(page).selectOption('weathertech-raceway-laguna-seca');
  await expect(page.getByTestId('noise-limit')).toContainText('Límite de ruido: 92 dB');
  await page.goto('./#/tires');
  await expect(page.getByText('Medidas de fábrica (índice de carga / velocidad)')).toBeVisible();
  expect(await serious(page)).toEqual([]);
  expect(csp).toEqual([]);
});
