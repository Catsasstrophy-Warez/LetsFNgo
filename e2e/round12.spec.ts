import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync, readFileSync } from 'node:fs';
import { radialLine, sessionFromFixes, syntheticCircuit } from '../src/lib/lapTimer';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

async function seed(page: Page, extra: Record<string, unknown> = {}, lang: 'en' | 'es' = 'en', theme: 'dark' | 'light' = 'dark') {
  await page.addInitScript(([l, t, x]) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t, lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    for (const [k, v] of Object.entries(x as Record<string, unknown>)) localStorage.setItem(k, JSON.stringify(v));
  }, [lang, theme, extra] as const);
}
const goto = async (page: Page, route: string) => { await page.goto(`./#${route}`); await expect(page.locator('main h1').first()).toBeVisible(); };
const serious = async (page: Page) => (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()).violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id);
const cspErrors = (page: Page) => { const errs: string[] = []; page.on('console', (m) => { if (m.type() === 'error' && /Content Security Policy/i.test(m.text())) errs.push(m.text()); }); return errs; };

function gpsSession() {
  const s = sessionFromFixes(syntheticCircuit({ laps: 3.3, jitterM: 1 }), radialLine(-Math.PI / 2), [radialLine(0), radialLine(Math.PI)]);
  return { id: 'gps1', date: '2026-06-01', track: 'Synthetic oval', conditions: '', airTemp: '', pressures: { fl: '', fr: '', rl: '', rr: '' }, laps: s!.text, notes: '', gps: s!.gps };
}
/** A real 2×2 PNG, so the browser decodes, resizes and re-encodes it as JPEG. */
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP4z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==', 'base64');

for (const theme of ['dark', 'light'] as const) {
  test(`track map from a stored GPS session (${theme})`, async ({ page }, info) => {
    const csp = cspErrors(page);
    await seed(page, { 'gt500.track.v1': [gpsSession()] }, 'en', theme);
    await goto(page, '/track');
    const fig = page.getByRole('figure').filter({ hasText: 'Track map (speed)' });
    await expect(fig).toBeVisible();
    await expect(fig.locator('.tm-seg').first()).toBeVisible();
    await expect(fig.locator('.tm-sector')).toHaveCount(2);
    await expect(page.getByRole('table').filter({ hasText: 'Theoretical best' })).toBeVisible();
    const box = (await fig.locator('svg').boundingBox())!;
    await fig.locator('svg').click({ position: { x: box.width / 2, y: 20 } });
    await expect(page.getByRole('status').filter({ hasText: /s into the lap/ })).toBeVisible();
    await page.getByLabel('Lap on map').selectOption({ index: 1 });
    await page.getByLabel('Point along the lap').focus();
    await page.keyboard.press('End');
    await expect(page.getByRole('status').filter({ hasText: /s into the lap/ })).toBeVisible();
    await page.getByRole('button', { name: 'Show data table' }).first().click();
    await expect(page.getByRole('table').filter({ hasText: 'samples' })).toBeVisible();
    await shot(page, `track-map-${theme}`, info.project.name);
    expect(await serious(page)).toEqual([]);
    expect(csp).toEqual([]);
  });
}

test('photos: attach to a service entry, view, export with photos, delete', async ({ page }, info) => {
  const csp = cspErrors(page);
  await seed(page);
  await goto(page, '/garage');
  await page.getByLabel('Service log: What').fill('Brake fluid flush');
  await page.getByLabel('Service log: What').press('Enter');
  await page.getByLabel('Add photo to Brake fluid flush').setInputFiles({ name: 'p.png', mimeType: 'image/png', buffer: PNG });
  const thumb = page.getByRole('button', { name: 'Open photo 1 of Brake fluid flush' });
  await expect(thumb).toBeVisible();
  await expect(page.getByText('1 of 6 photos')).toBeVisible();
  await page.getByLabel('Add photo to Brake fluid flush').setInputFiles({ name: 'x.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') });
  await expect(page.getByRole('alert').filter({ hasText: 'not an image' })).toBeVisible();
  await thumb.click();
  const dlg = page.getByRole('dialog');
  await expect(dlg).toBeVisible();
  await expect(dlg.getByRole('img')).toBeVisible();
  await shot(page, 'photo-lightbox', info.project.name);
  expect(await serious(page)).toEqual([]);
  await dlg.getByRole('button', { name: 'Close' }).click();
  await expect(dlg).toBeHidden();

  await goto(page, '/settings');
  await page.getByLabel('Include photos (larger file)').check();
  const dl = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export JSON' }).click();
  const file = await (await dl).path();
  const json = JSON.parse(readFileSync(file!, 'utf8'));
  expect(json.schema).toBe(9);
  expect(json.photos).toHaveLength(1);
  expect(json.photos[0].data.startsWith('/9j/')).toBe(true);
  expect(json.photos[0].w).toBe(2);
  await expect(page.getByText(/Backup with 1 photo downloaded/)).toBeVisible();
  // Default export has no photos.
  await page.getByLabel('Include photos (larger file)').uncheck();
  const dl2 = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export JSON' }).click();
  expect(JSON.parse(readFileSync((await (await dl2).path())!, 'utf8')).photos).toBeUndefined();

  await goto(page, '/garage');
  page.on('dialog', (d) => d.accept());
  await page.getByRole('button', { name: 'Open photo 1 of Brake fluid flush' }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Delete' }).click();
  await expect(page.getByRole('button', { name: 'Open photo 1 of Brake fluid flush' })).toHaveCount(0);
  expect(csp).toEqual([]);
});

test('pre-track checklist is saved with the session', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/track');
  const box = page.locator('fieldset.ptc');
  await expect(box).toContainText('DOT 4 LV');
  await expect(box).toContainText('No Ford-sourced GT500 track pressure');
  await box.getByLabel('New checklist item').fill('Torque lug nuts');
  await box.getByRole('button', { name: 'Add item' }).click();
  await box.getByLabel(/Brake fluid replaced/).check();
  await box.getByRole('checkbox', { name: 'Torque lug nuts' }).check();
  await expect(box).toContainText('2 of 6 done');
  await shot(page, 'pretrack-checklist', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.getByLabel('Track', { exact: true }).fill('VIR');
  await page.getByRole('button', { name: 'Save session' }).click();
  await expect(page.getByText('Pre-track checklist: 2 of 6 done')).toBeVisible();
  // The next session starts unticked but keeps the owner's own item.
  await expect(box).toContainText('0 of 6 done');
  await expect(box.getByRole('checkbox', { name: 'Torque lug nuts' })).not.toBeChecked();
});

test('car-color accent follows the paint with AA contrast, and falls back', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/garage');
  await page.locator('select').filter({ has: page.locator('option[value="race-red"]') }).selectOption('grabber-lime');
  await goto(page, '/settings');
  await page.getByRole('radio', { name: 'From my car’s paint' }).click();
  await expect(page.getByText(/adjusted for contrast/)).toBeVisible();
  const accent = await page.evaluate(() => document.documentElement.style.getPropertyValue('--accent'));
  expect(accent).toMatch(/^#[0-9a-f]{6}$/);
  await shot(page, 'accent-settings', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.getByRole('button', { name: 'Toggle theme' }).click();
  expect(await serious(page)).toEqual([]);
  await goto(page, '/garage');
  await page.locator('select').filter({ has: page.locator('option[value="race-red"]') }).selectOption('shadow-black');
  await goto(page, '/settings');
  await expect(page.getByText(/too close to grey/)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.style.getPropertyValue('--accent'))).toBe('');
});

test('lap timer: known track without a sourced line explains it, no "Use sourced line"', async ({ page }) => {
  await seed(page);
  await goto(page, '/laptimer');
  await page.getByLabel('Known track (optional)').selectOption('sonoma-raceway');
  await expect(page.getByText('No sourced start/finish line for this track yet')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Use sourced line' })).toHaveCount(0);
  await expect(page.getByLabel('Track', { exact: true })).toHaveValue('Sonoma Raceway');
  expect(await serious(page)).toEqual([]);
});

test('Spanish: track map, checklist and photo controls are translated', async ({ page }) => {
  await seed(page, { 'gt500.track.v1': [gpsSession()] }, 'es');
  await goto(page, '/track');
  await expect(page.getByText('Mapa del circuito (velocidad)')).toBeVisible();
  await expect(page.locator('fieldset.ptc')).toContainText('Lista previa al circuito');
  await expect(page.getByText('Añadir foto').first()).toBeVisible();
  expect(await serious(page)).toEqual([]);
});

test('lap timer: "Use sourced line" warns it is derived/unverified and credits OpenStreetMap when used', async ({ page }) => {
  await seed(page);
  await goto(page, '/laptimer');
  await page.getByLabel('Known track (optional)').selectOption('circuit-of-the-americas');
  await expect(page.getByText('derived from map data and unverified')).toBeVisible();
  await expect(page.getByRole('link', { name: '© OpenStreetMap contributors' }).first()).toHaveAttribute('href', 'https://www.openstreetmap.org/copyright');
  await page.getByRole('button', { name: 'Use sourced line' }).click();
  await expect(page.getByText('Using a sourced line (derived, unverified).')).toBeVisible();
  await expect(page.locator('.sfl-inuse a')).toHaveAttribute('href', 'https://www.openstreetmap.org/copyright');
  await expect(page.getByRole('button', { name: 'Drop line here' })).toBeVisible();
  expect(await serious(page)).toEqual([]);
  for (const route of ['/sources', '/help']) {
    await goto(page, route);
    await expect(page.locator('main a[href="https://www.openstreetmap.org/copyright"]').first()).toBeVisible();
    expect(await serious(page)).toEqual([]);
  }
});
