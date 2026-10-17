import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

/** A returning single-car user from before multi-car support (legacy key, logs without carId). */
async function seedLegacy(page: Page, lang: 'en' | 'es' = 'en') {
  await page.addInitScript((l) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: 'dark', lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.garage.v1', JSON.stringify({ year: '2020', color: 'race-red', nickname: 'Snake', vin: '1FA6P8SJ0L5500000', odometer: '4200',
      service: [{ id: 's', date: '2025-01-01', title: 'Oil change', notes: 'Motorcraft', miles: '1200', cost: '150' }],
      reminders: [{ id: 'r', item: 'Brake fluid', everyMiles: null, everyMonths: 36, lastMiles: null, lastDate: '2025-03-01' }, { id: 'p', item: 'Plugs', everyMiles: 100000, everyMonths: null, lastMiles: 0, lastDate: '' }] }));
    const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
    localStorage.setItem('gt500.drag.v1', JSON.stringify([{ id: 'a', date: '2026-03-01', track: 'Lucky Strip', rt: 0.5, sixty: 1.7, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: 10.9, quarterMph: 128, da: 2000, weather: w, mods: [], notes: '' }]));
  }, lang);
}
const goto = async (page: Page, route: string) => { await page.goto(`./#${route}`); await expect(page.locator('main h1').first()).toBeVisible(); };

test('multi-car: legacy data becomes car #1; add, switch and delete a car; logs stay per car', async ({ page }, info) => {
  await seedLegacy(page);
  await goto(page, '/garage');
  await expect(page.getByLabel('Nickname')).toHaveValue('Snake');
  await expect(page.getByRole('banner').getByLabel('Active car')).toHaveCount(0); // one car: no header switcher
  await page.getByRole('button', { name: 'Add another car' }).click();
  await expect(page.getByLabel('Nickname')).toHaveValue('');
  await page.getByLabel('Nickname').fill('Blue');
  const sw = page.getByRole('banner').getByLabel('Active car');
  await expect(sw).toBeVisible();
  await expect(sw.locator('option')).toHaveText(['Snake', 'Blue']);
  await shot(page, 'garage-two-cars', info.project.name);
  // The new car has its own (empty) drag log.
  await goto(page, '/drag');
  await expect(page.getByText('Lucky Strip')).toHaveCount(0);
  await sw.selectOption({ label: 'Snake' });
  await expect(page.getByText('Lucky Strip').first()).toBeVisible();
  // Storage: legacy key untouched, cars key holds both.
  const st = await page.evaluate(() => ({ cars: JSON.parse(localStorage.getItem('gt500.cars.v1')!), legacy: JSON.parse(localStorage.getItem('gt500.garage.v1')!) }));
  expect(st.cars.cars.map((c: { nickname: string }) => c.nickname)).toEqual(['Snake', 'Blue']);
  expect(st.cars.cars[0].service[0].title).toBe('Oil change');
  expect(st.legacy.nickname).toBe('Snake');
  // Delete the second car.
  await sw.selectOption({ label: 'Blue' });
  await goto(page, '/garage');
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Delete this car' }).click();
  await expect(page.getByLabel('Nickname')).toHaveValue('Snake');
  await expect(page.getByRole('banner').getByLabel('Active car')).toHaveCount(0);
});

test('service report: print-ready page with disclaimer, HTML download is standalone', async ({ page }, info) => {
  await seedLegacy(page);
  await goto(page, '/report');
  await expect(page.getByRole('heading', { name: 'Service history — Snake' })).toBeVisible();
  await expect(page.getByText('Owner-entered, not verified').first()).toBeVisible();
  await expect(page.getByRole('button', { name: 'Print / save as PDF' })).toBeVisible();
  await page.getByLabel('VIN on the report').selectOption('last6');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download HTML' }).click()]);
  expect(dl.suggestedFilename()).toMatch(/^snake-service-history-\d{4}-\d{2}-\d{2}\.html$/);
  const html = await readFile((await dl.path())!, 'utf8');
  expect(html).toContain('Owner-entered, not verified');
  expect(html).toContain('Oil change');
  expect(html).not.toContain('1FA6P8SJ0L5500000');
  expect(html).toContain('500000');
  expect(html).not.toMatch(/<script/);
  await page.emulateMedia({ media: 'print' });
  await expect(page.locator('.topbar')).toBeHidden();
  await expect(page.getByRole('button', { name: 'Print / save as PDF' })).toBeHidden();
  await shot(page, 'report-print', info.project.name);
  await page.emulateMedia({ media: 'screen' });
});

test('maintenance reminders download as a valid .ics file', async ({ page }) => {
  await seedLegacy(page);
  await goto(page, '/garage');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download calendar (.ics)' }).click()]);
  expect(dl.suggestedFilename()).toMatch(/\.ics$/);
  const ics = await readFile((await dl.path())!, 'utf8');
  expect(ics.startsWith('BEGIN:VCALENDAR\r\nVERSION:2.0\r\n')).toBe(true);
  expect(ics).toContain('SUMMARY:Brake fluid');
  expect(ics).toContain('DTSTART;VALUE=DATE:20280301');
  expect(ics.trimEnd().endsWith('END:VCALENDAR')).toBe(true);
  await expect(page.getByRole('status').filter({ hasText: 'mileage-only' })).toBeVisible();
});

test('keyboard shortcuts: ?, Esc, g-sequences and / (ignored while typing)', async ({ page }, info) => {
  test.skip(info.project.name === 'mobile', 'desktop keyboards only');
  await seedLegacy(page);
  await goto(page, '/');
  await page.keyboard.press('?');
  const dlg = page.getByRole('dialog', { name: 'Keyboard shortcuts' });
  await expect(dlg).toBeVisible();
  const res = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(res.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  await shot(page, 'shortcuts', info.project.name);
  await page.keyboard.press('Escape');
  await expect(dlg).toBeHidden();
  await page.keyboard.press('g'); await page.keyboard.press('s');
  await expect(page).toHaveURL(/#\/specs$/);
  await page.keyboard.press('g'); await page.keyboard.press('g');
  await expect(page).toHaveURL(/#\/garage$/);
  // Typing in a field never triggers shortcuts.
  await page.getByLabel('Nickname').fill('');
  await page.getByLabel('Nickname').pressSequentially('g h/?');
  await expect(page.getByLabel('Nickname')).toHaveValue('g h/?');
  await expect(page).toHaveURL(/#\/garage$/);
  await expect(dlg).toBeHidden();
  await page.locator('h1').first().click();
  await page.keyboard.press('/');
  await expect(page).toHaveURL(/#\/search$/);
  await expect(page.getByRole('searchbox')).toBeFocused();
});

test('market value: charts, filters, outlier toggle and your-car marker', async ({ page }, info) => {
  await seedLegacy(page);
  await goto(page, '/market');
  await page.getByRole('heading', { name: 'Price charts' }).scrollIntoViewIfNeeded();
  await expect(page.getByText('Price vs sale date', { exact: true })).toBeVisible();
  await expect(page.getByText('Your car: 4,200 mi', { exact: true })).toBeVisible();
  await expect(page.getByText(/Edsel Ford II/)).toHaveCount(0);
  await page.getByLabel('Include outliers (e.g. celebrity provenance)').check();
  await page.getByRole('heading', { name: 'Results', exact: true }).scrollIntoViewIfNeeded();
  await expect(page.getByText(/Edsel Ford II/).first()).toBeVisible();
  await page.getByLabel('CFTP').selectOption('yes');
  await expect(page.getByText('1 of 22 results · 0 with a USD price')).toBeVisible();
  await expect(page.getByText(/no results with a USD price match/).first()).toBeVisible();
  await shot(page, 'market-cftp', info.project.name);
});

test('achievements and Spanish Garage', async ({ page }, info) => {
  await seedLegacy(page, 'es');
  await goto(page, '/achievements');
  await expect(page.getByRole('heading', { name: 'Logros', level: 1 })).toBeVisible();
  await expect(page.getByText('Auto de diez segundos')).toBeVisible();
  await expect(page.getByText('Logrado el 2026-03-01').first()).toBeVisible();
  await shot(page, 'achievements-es', info.project.name);
  await goto(page, '/garage');
  await expect(page.getByRole('heading', { name: 'Mi garaje', level: 1 })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Agregar otro auto' })).toBeVisible();
});

test('importing a v4 (single-car) backup migrates it to the multi-car Garage', async ({ page }, info) => {
  await seedLegacy(page);
  await goto(page, '/settings');
  const v4 = { app: 'gt500-companion', schema: 4, exported: '', garage: { nickname: 'Imported', year: '2021' }, plans: [], track: [], drag: [], fuel: [], settings: { units: 'imperial', theme: 'dark' }, onboarding: { done: true, completed: '' }, dyno: [], notify: { enabled: false, sent: {} }, dashboard: { order: [], hidden: [] } };
  page.once('dialog', (d) => d.accept());
  await page.locator('input[type=file]').setInputFiles({ name: 'old.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(v4)) });
  await expect(page.getByText(/Imported 1 car,.*Upgraded from schema v4/)).toBeVisible();
  await goto(page, '/garage');
  await expect(page.getByLabel('Nickname')).toHaveValue('Imported');
  await shot(page, 'import-v4', info.project.name);
});
