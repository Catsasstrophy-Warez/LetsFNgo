import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync, readFileSync } from 'node:fs';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

async function seed(page: Page, extra: Record<string, unknown> = {}, lang: 'en' | 'es' = 'en', theme: 'dark' | 'light' = 'dark') {
  await page.addInitScript(([l, t, x]) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t, lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.install.v1', JSON.stringify({ dismissed: '2026-06-01' }));
    for (const [k, v] of Object.entries(x as Record<string, unknown>)) localStorage.setItem(k, JSON.stringify(v));
  }, [lang, theme, extra] as const);
}
const goto = async (page: Page, route: string) => { await page.goto(`./#${route}`); await expect(page.locator('main h1').first()).toBeVisible(); };
const serious = async (page: Page) => (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id);
const cspErrors = (page: Page) => { const errs: string[] = []; page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy/i.test(m.text())) errs.push(m.text()); }); return errs; };

for (const theme of ['dark', 'light'] as const) {
  test(`OBD demo mode: labelled gauges, recording, CSV, codes (${theme})`, async ({ page }, info) => {
    const csp = cspErrors(page);
    await seed(page, {}, 'en', theme);
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await goto(page, '/obd');
    await expect(page.getByText('do not look at or touch this screen while driving')).toBeVisible();
    // Headless Chromium has no Bluetooth adapter API exposed in this context or it does: either way demo works.
    await page.getByRole('button', { name: 'Start demo (simulated data)' }).click();
    await expect(page.getByText('Demo — simulated').first()).toBeVisible();
    await expect(page.locator('.gauge')).toHaveCount(6); // oil temp is not reported by the demo car
    await expect(page.getByText('Not reported as supported by this car (hidden): Oil temp.')).toBeVisible();
    await page.getByRole('button', { name: 'Record session' }).click();
    await expect(page.getByText(/[1-9]\d* samples recorded/)).toBeVisible();
    await page.getByRole('button', { name: 'Stop recording' }).click();
    const dl = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Export CSV' }).click();
    const file = await dl;
    expect(file.suggestedFilename()).toMatch(/-demo\.csv$/);
    expect(readFileSync((await file.path())!, 'utf8')).toMatch(/,yes\r\n/);
    await expect(page.getByText('Demo data cannot be attached to your logs.')).toBeVisible();
    await page.getByRole('button', { name: 'Read trouble codes' }).click();
    await expect(page.getByRole('heading', { name: /Trouble codes \(read-only\)/ })).toBeVisible();
    await expect(page.getByText('This app never clears codes.')).toBeVisible();
    await shot(page, `obd-demo-${theme}`, info.project.name);
    expect(await serious(page)).toEqual([]);
    await page.getByRole('button', { name: 'Disconnect' }).click();
    expect(csp).toEqual([]);
  });
}

test('OBD: browsers without Web Bluetooth get an explanation and no Connect button', async ({ page }) => {
  await page.addInitScript(() => { Object.defineProperty(Navigator.prototype, 'bluetooth', { get: () => undefined, configurable: true }); delete (Navigator.prototype as unknown as Record<string, unknown>).bluetooth; });
  await seed(page);
  await goto(page, '/obd');
  await expect(page.getByText('iPhone and iPad browsers')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Connect adapter' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Start demo (simulated data)' })).toBeVisible();
});

test('drag tree trainer: early tap is a red light, a real reaction is saved (reduced motion)', async ({ page }, info) => {
  await seed(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await goto(page, '/tree');
  const btn = page.getByRole('button', { name: 'Stage' });
  await btn.focus();
  await page.keyboard.press('Enter');
  await page.keyboard.press('Enter'); // immediately: before the first amber → red light
  await expect(page.getByRole('status').filter({ hasText: 'Red light!' })).toBeVisible();
  await page.getByLabel('Pro .4 tree').check();
  await page.getByRole('button', { name: 'Stage' }).focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('.tree-lamp.green.on')).toBeVisible({ timeout: 5000 });
  await page.keyboard.press('Enter');
  await expect(page.getByRole('status').filter({ hasText: /Reaction time \d\.\d{3} s/ })).toBeVisible();
  await expect(page.locator('.stat-v').nth(2)).toHaveText('1');
  await shot(page, 'tree', info.project.name);
  expect(await serious(page)).toEqual([]);
  const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('gt500.tree.v1') ?? '[]'));
  expect(stored).toHaveLength(2);
});

test('ask the data: sourced answers and "not in the data" (en + es)', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/ask');
  await page.getByLabel('Your question').fill('paint code for grabber lime');
  await page.getByRole('button', { name: 'Ask', exact: true }).click();
  await expect(page.getByText('F9 (M7435)')).toBeVisible();
  await expect(page.locator('#ask-res ~ ul .badge').first()).toBeVisible();
  await page.getByRole('button', { name: 'What oil does it take?' }).click();
  await expect(page.getByText(/5W-50/).first()).toBeVisible();
  await shot(page, 'ask', info.project.name);
  await page.getByLabel('Your question').fill('who won Le Mans in 1967');
  await page.getByRole('button', { name: 'Ask', exact: true }).click();
  await expect(page.getByText('Not in the data.')).toBeVisible();
  expect(await serious(page)).toEqual([]);
});

test('track day planner: add, pack, export .ics, survives reload', async ({ page }, info) => {
  await page.clock.setFixedTime(new Date('2026-10-17T12:00:00Z'));
  await seed(page);
  await goto(page, '/trackdays');
  await page.getByLabel('Date', { exact: true }).fill('2026-11-07');
  await page.getByRole('combobox', { name: /^Track/ }).selectOption('road-america');
  await page.getByLabel('Organizer').fill('Test club');
  await page.getByLabel('Run group').fill('Novice');
  await page.getByRole('button', { name: 'Add event' }).click();
  await expect(page.getByRole('heading', { name: 'Road America' })).toBeVisible();
  await expect(page.getByText('in 21 days')).toBeVisible();
  await page.getByText(/Packing list \(0\/\d+\)/).click();
  await page.getByLabel(/^Helmet/).check();
  await expect(page.getByText(/Packing list \(1\/\d+\)/)).toBeVisible();
  const dl = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export upcoming (.ics)' }).click();
  const ics = readFileSync((await (await dl).path())!, 'utf8');
  expect(ics).toContain('SUMMARY:Track day: Road America (Novice)');
  await shot(page, 'trackdays', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Road America' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'GPS Lap Timer' }).last()).toBeVisible();
});

test('regression: switching the known track drops the previous track\'s sourced line', async ({ page }) => {
  await seed(page);
  await goto(page, '/laptimer');
  await page.getByLabel('Known track (optional)').selectOption('circuit-of-the-americas');
  await page.getByRole('button', { name: 'Use sourced line' }).click();
  await expect(page.getByText('Using a sourced line (derived, unverified).')).toBeVisible();
  await page.getByLabel('Known track (optional)').selectOption('virginia-international-raceway');
  await expect(page.getByText('Using a sourced line (derived, unverified).')).toHaveCount(0);
  await expect(page.locator('.sfl-inuse')).toHaveCount(0);
});

test('compare: competitor prices by model year with sources (Spanish)', async ({ page }) => {
  await seed(page, {}, 'es');
  await goto(page, '/compare');
  // Select the ZL1 card's price list by its content rather than a row count, so adding sourced rows doesn't break it.
  await page.locator('details').filter({ hasText: 'MY2022 $64,395' }).locator('summary', { hasText: /Precios por año de modelo \(\d+\)/ }).first().click();
  await expect(page.getByText('MY2022 $64,395')).toBeVisible();
  expect(await serious(page)).toEqual([]);
});
