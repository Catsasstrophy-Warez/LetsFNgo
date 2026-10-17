import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

async function seed(page: Page, lang: 'en' | 'es' = 'en') {
  await page.addInitScript((l) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: 'dark', lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.install.v1', JSON.stringify({ dismissed: '2026-06-01' }));
    localStorage.setItem('gt500.cars.v1', JSON.stringify({ active: 'car1', cars: [
      { id: 'car1', vin: '', year: '2020', color: '', nickname: 'Snake', odometer: '', mods: [], service: [{ id: 's1', date: '2026-01-02', title: 'Oil change', notes: '', cost: '$180' }], reminders: [] },
      { id: 'car2', vin: '', year: '2022', color: '', nickname: 'Second', odometer: '', mods: [], service: [], reminders: [] },
    ] }));
  }, lang);
}
const serious = async (page: Page) => (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id);
const cspErrors = (page: Page) => { const errs: string[] = []; page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy/i.test(m.text())) errs.push(m.text()); }); return errs; };

test('Cost of ownership: inputs, unpriced services, user vs sourced, per-car persistence', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page);
  await page.goto('./#/cost');
  await expect(page.getByRole('heading', { level: 1, name: 'Cost of Ownership' })).toBeVisible();
  await expect(page.getByText('Enter miles per year and years of ownership')).toBeVisible();

  await page.getByLabel('Miles per year').fill('5000');
  await page.getByLabel('Years of ownership').fill('2');
  await page.getByLabel('Insurance ($ per year)').fill('2000');
  const total = page.locator('tfoot [role=status]');
  await expect(total).toContainText('at least $2,000');
  await expect(total).toContainText('without a price');
  await expect(page.getByText('price not sourced').first()).toBeVisible();

  await page.getByLabel('Your cost per service: Engine oil & filter').fill('150');
  await expect(total).toContainText('at least $2,150');
  await page.getByLabel('What you paid ($)').fill('80000');
  await expect(page.getByRole('rowheader', { name: /DriveIndex median/ }).first()).toBeVisible();
  await expect(page.getByRole('row', { name: /Service log \(1 entry\)/ })).toContainText('$180');
  expect(await serious(page)).toEqual([]);

  await page.reload();
  await expect(page.getByLabel('Miles per year')).toHaveValue('5000');
  await expect(total).toContainText('at least $2,150');
  expect(csp).toEqual([]);
});

test('Cost of ownership in Spanish', async ({ page }) => {
  const csp = cspErrors(page);
  await seed(page, 'es');
  await page.goto('./#/cost');
  await expect(page.getByRole('heading', { level: 1, name: 'Costo de propiedad' })).toBeVisible();
  await page.getByLabel('Millas por año').fill('8000');
  await page.getByLabel('Años de propiedad').fill('3');
  await expect(page.getByText('precio sin fuente').first()).toBeVisible();
  expect(await serious(page)).toEqual([]);
  expect(csp).toEqual([]);
});
