import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync } from 'node:fs';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

const ROUTES = ['/', '/specs', '/years', '/colors', '/visualizer', '/packages', '/performance', '/vin', '/ownership', '/garage', '/planner',
  '/timeline', '/track', '/timer', '/drag', '/gps', '/fuel', '/gearing', '/tools', '/mods', '/compare', '/diff', '/media', '/community',
  '/quiz', '/print', '/sources', '/settings', '/search', '/welcome'];

/** Seed a returning user so Home does not redirect to the intro, with some data so log pages render content. */
async function seed(page: Page, theme: 'dark' | 'light') {
  await page.addInitScript((t) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.garage.v1', JSON.stringify({ year: '2020', color: 'race-red', nickname: 'Snake', mods: [{ id: 'm', date: '2025-06-01', title: 'Tune', notes: '', cost: '900' }], service: [{ id: 's', date: '2025-01-01', title: 'Oil change', notes: '', cost: '150' }] }));
    localStorage.setItem('gt500.plans.v1', JSON.stringify([{ id: 'p', name: 'Big', modIds: ['vmp', 'hpj'], created: '' }]));
    const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
    localStorage.setItem('gt500.drag.v1', JSON.stringify([{ id: 'a', date: '2026-03-01', track: 'Texas Motorplex', rt: 0.5, sixty: 1.7, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: 11.2, quarterMph: 128, da: 2000, weather: w, mods: [], notes: '' }]));
  }, theme);
}

async function goto(page: Page, route: string) {
  await page.goto(`./#${route}`);
  await expect(page.locator('main h1').first()).toBeVisible();
}

for (const theme of ['dark', 'light'] as const) {
  test(`axe: no serious/critical violations on every route (${theme})`, async ({ page }, info) => {
    await seed(page, theme);
    const failures: string[] = [];
    for (const r of ROUTES) {
      await goto(page, r);
      await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
      const res = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('iframe').analyze();
      for (const v of res.violations.filter((x) => x.impact === 'serious' || x.impact === 'critical')) {
        failures.push(`${r} [${v.impact}] ${v.id}: ${v.nodes.slice(0, 3).map((n) => n.target.join(' ')).join(' | ')}`);
      }
      if (['/timer', '/gps', '/timeline', '/diff', '/planner', '/welcome'].includes(r)) await shot(page, `${theme}${r.replace(/\//g, '-')}`, info.project.name);
    }
    expect(failures, failures.join('\n')).toEqual([]);
  });
}

test('first run shows the intro, seeds the Garage, and can be re-run from Settings', async ({ page }) => {
  await page.goto('./');
  await expect(page.getByRole('heading', { name: 'Welcome' })).toBeVisible();
  await page.getByLabel('Model year').selectOption('2021');
  await page.getByRole('button', { name: /Carbonized Gray/ }).click();
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByRole('textbox', { name: 'VIN' }).fill('1FA6P8SJ0M5500000');
  await page.getByRole('button', { name: 'Next' }).click();
  await page.getByRole('radio', { name: /Metric/ }).click();
  await page.getByRole('button', { name: 'Finish' }).click();
  await expect(page).toHaveURL(/#\/garage/);
  const g = await page.evaluate(() => JSON.parse(localStorage.getItem('gt500.garage.v1') || '{}'));
  expect(g.year).toBe('2021'); expect(g.color).toBe('carbonized-gray');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('gt500.settings.v1') || '{}').units)).toBe('metric');
  await goto(page, '/');
  await expect(page.getByRole('heading', { name: 'Welcome' })).toHaveCount(0);
  await goto(page, '/settings');
  await page.getByRole('button', { name: 'Run intro again' }).click();
  await expect(page.getByRole('heading', { name: 'Welcome' })).toBeVisible();
  await page.getByRole('button', { name: 'Skip intro' }).click();
  await expect(page.getByRole('heading', { name: 'Welcome' })).toHaveCount(0);
});

test('session timer records laps and saves to the Track log', async ({ page }, info) => {
  await seed(page, 'dark');
  await goto(page, '/timer');
  await page.getByRole('button', { name: 'Start' }).click();
  await page.waitForTimeout(1200);
  await page.getByRole('button', { name: 'Lap' }).click();
  await page.waitForTimeout(1100);
  await page.getByRole('button', { name: 'Lap' }).click();
  await page.getByRole('button', { name: 'Pause' }).click();
  await expect(page.locator('.lap-list li')).toHaveCount(2);
  await page.getByLabel('Track').fill('Laguna Seca');
  await page.getByRole('button', { name: 'Save to Track log' }).click();
  await expect(page.getByText('Saved 2 laps to the Track log.')).toBeVisible();
  await shot(page, 'timer-saved', info.project.name);
  await goto(page, '/track');
  await expect(page.getByRole('heading', { name: 'Laguna Seca' })).toBeVisible();
});

test('GPS meter: permission denied is handled', async ({ browser, baseURL }) => {
  const ctx = await browser.newContext({ baseURL, permissions: [] });
  const page = await ctx.newPage();
  await page.addInitScript(() => localStorage.setItem('gt500.onboarding.v1', '{"done":true,"completed":""}'));
  await page.addInitScript(() => {
    navigator.geolocation.watchPosition = (_ok, err) => { setTimeout(() => err?.({ code: 1, message: 'denied', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 } as GeolocationPositionError), 50); return 1; };
  });
  await goto(page, '/gps');
  await expect(page.getByText('Arm GPS')).toBeVisible();
  await page.getByRole('button', { name: 'Arm GPS' }).click();
  await expect(page.getByRole('alert')).toContainText('permission was denied');
  await ctx.close();
});

test('GPS meter: real permission grant shows accuracy and warns when poor', async ({ browser, baseURL }, info) => {
  const ctx = await browser.newContext({ baseURL, permissions: ['geolocation'], geolocation: { latitude: 33, longitude: -97, accuracy: 40 }, viewport: info.project.use.viewport ?? undefined });
  const page = await ctx.newPage();
  await page.addInitScript(() => localStorage.setItem('gt500.onboarding.v1', '{"done":true,"completed":""}'));
  await goto(page, '/gps');
  // never auto-starts
  await expect(page.locator('.stat-v').first()).toHaveText('Off');
  await page.getByRole('button', { name: 'Arm GPS' }).click();
  await expect(page.getByText(/Accuracy is worse than/)).toBeVisible();
  await expect(page.getByText('(too poor)')).toBeVisible();
  await shot(page, 'gps-poor', info.project.name);
  await page.getByRole('button', { name: 'Cancel' }).click();
  await ctx.close();
});

test('GPS meter: synthetic 0–60 run is timed and saved as a GPS estimate', async ({ page }, info) => {
  await seed(page, 'dark');
  await page.addInitScript(() => {
    // Feed a synthetic launch (stop 1 s, then 7.66 m/s² ≈ 0–60 in 3.5 s) at 10 Hz.
    navigator.geolocation.watchPosition = (ok) => {
      const t0 = Date.now(); let i = 0;
      const id = setInterval(() => {
        const tt = i / 10, run = Math.max(0, tt - 1), a = 26.8224 / 3.5, d = 0.5 * a * run * run;
        ok({ timestamp: t0 + tt * 1000, coords: { latitude: 33 + d / 111195, longitude: -97, accuracy: 3, speed: a * run, altitude: null, altitudeAccuracy: null, heading: null } } as unknown as GeolocationPosition);
        if (++i > 80) clearInterval(id);
      }, 10);
      return id as unknown as number;
    };
    navigator.geolocation.clearWatch = (id) => clearInterval(id);
  });
  await goto(page, '/gps');
  await page.getByRole('button', { name: 'Arm GPS' }).click();
  await expect(page.getByText(/^3\.[45]\d s/)).toBeVisible();
  await shot(page, 'gps-result', info.project.name);
  await page.getByRole('button', { name: 'Save to Drag log' }).click();
  await expect(page.getByText('Saved to the Drag log as a GPS estimate.')).toBeVisible();
  await goto(page, '/drag');
  await expect(page.getByText('GPS estimate').first()).toBeVisible();
  await expect(page.getByRole('heading', { name: /0–60 mph/ })).toBeVisible();
});

test('timeline filters and planner warnings', async ({ page }, info) => {
  await seed(page, 'light');
  await goto(page, '/timeline');
  await expect(page.locator('.tl')).toHaveCount(3);
  await page.getByLabel('Drag').uncheck();
  await expect(page.locator('.tl')).toHaveCount(2);
  await page.getByRole('combobox', { name: /^Year/ }).selectOption('2025');
  await expect(page.getByRole('status').filter({ hasText: 'entries' })).toHaveText('2 of 3 entries');
  await goto(page, '/planner');
  await expect(page.getByText('Torque above the reported DCT clutch rating')).toBeVisible();
  await shot(page, 'planner-warnings', info.project.name);
  await goto(page, '/diff');
  await page.getByLabel('Rival').selectOption('superstock');
  await expect(page.getByRole('cell', { name: /807 hp/ })).toBeVisible();
});
