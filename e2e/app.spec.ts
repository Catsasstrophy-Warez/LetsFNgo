import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { mkdirSync } from 'node:fs';

const SHOTS = process.env.SCREENS_DIR;
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const shot = async (page: Page, name: string, project: string) => { if (SHOTS) await page.screenshot({ path: `${SHOTS}/${project}-${name}.png`, fullPage: true }); };

const ROUTES = ['/', '/specs', '/years', '/colors', '/visualizer', '/packages', '/performance', '/vin', '/ownership', '/garage', '/planner',
  '/timeline', '/track', '/timer', '/drag', '/gps', '/fuel', '/gearing', '/tools', '/mods', '/compare', '/diff', '/media', '/community',
  '/quiz', '/print', '/sources', '/settings', '/search', '/laptimer', '/welcome', '/dyno', '/tires', '/parts', '/guides', '/guides/track-service', '/guides/dct-fluid',
  '/report', '/market', '/achievements', '/editions', '/history', '/help', '/parts?tab=fp', '/coverage'];

/** Seed a returning user so Home does not redirect to the intro, with some data so log pages render content. */
async function seed(page: Page, theme: 'dark' | 'light', lang: 'en' | 'es' = 'en') {
  await page.addInitScript(([t, l]) => {
    if (sessionStorage.getItem('seeded')) return;
    sessionStorage.setItem('seeded', '1');
    localStorage.setItem('gt500.settings.v1', JSON.stringify({ units: 'imperial', theme: t, lang: l }));
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.garage.v1', JSON.stringify({ year: '2020', color: 'race-red', nickname: 'Snake', mods: [{ id: 'm', date: '2025-06-01', title: 'Tune', notes: '', cost: '900' }], service: [{ id: 's', date: '2025-01-01', title: 'Oil change', notes: '', cost: '150' }] }));
    localStorage.setItem('gt500.plans.v1', JSON.stringify([{ id: 'p', name: 'Big', modIds: ['vmp', 'hpj'], created: '' }]));
    const w = { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false };
    localStorage.setItem('gt500.drag.v1', JSON.stringify([{ id: 'a', date: '2026-03-01', track: 'Texas Motorplex', rt: 0.5, sixty: 1.7, threeThirty: null, eighthEt: null, eighthMph: null, quarterEt: 11.2, quarterMph: 128, da: 2000, weather: w, mods: [], notes: '' }]));
  }, [theme, lang]);
}

async function goto(page: Page, route: string) {
  await page.goto(`./#${route}`);
  await expect(page.locator('main h1').first()).toBeVisible();
}

for (const [theme, lang] of [['dark', 'en'], ['light', 'en'], ['dark', 'es'], ['light', 'es']] as const) {
  test(`axe: no serious/critical violations on every route (${theme}, ${lang})`, async ({ page }, info) => {
    test.setTimeout(180_000);
    await seed(page, theme, lang);
    const failures: string[] = [];
    for (const r of ROUTES) {
      await goto(page, r);
      // Lazy, below-the-fold content (Market charts) renders once scrolled into view: check it too.
      await expect.poll(() => page.evaluate(() => { const ph = document.querySelector('.lazy-ph'); ph?.scrollIntoView(); return document.querySelectorAll('.lazy-ph').length; })).toBe(0);
      await page.evaluate(() => window.scrollTo(0, 0));
      await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
      await expect(page.locator('html')).toHaveAttribute('lang', lang);
      const res = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).exclude('iframe').analyze();
      for (const v of res.violations.filter((x) => x.impact === 'serious' || x.impact === 'critical')) {
        failures.push(`${r} [${v.impact}] ${v.id}: ${v.nodes.slice(0, 3).map((n) => n.target.join(' ')).join(' | ')}`);
      }
      if (['/timer', '/gps', '/timeline', '/diff', '/planner', '/welcome', '/dyno', '/tires', '/', '/parts', '/guides', '/guides/track-service', '/sources', '/settings', '/report', '/market', '/achievements', '/garage', '/editions', '/history', '/help', '/parts?tab=fp', '/coverage'].includes(r)) await shot(page, `${theme}-${lang}${r.replace(/[/?=]/g, '-')}`, info.project.name);
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
  const g = await page.evaluate(() => { const s = JSON.parse(localStorage.getItem('gt500.cars.v1') || '{}'); return s.cars.find((c: { id: string }) => c.id === s.active); });
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

test('dyno log: save a pull with a curve and see the overlay', async ({ page }, info) => {
  await seed(page, 'dark');
  await goto(page, '/dyno');
  await page.getByLabel('Peak whp').fill('682');
  await page.getByLabel(/Peak wheel torque/).fill('590');
  await page.getByLabel(/Curve points/).fill('3000, 300, 520\n5000, 520, 560\n7000, 682, 510');
  await page.getByRole('button', { name: 'Save pull' }).click();
  await expect(page.locator('.chart-svg polyline')).toHaveCount(2);
  await expect(page.locator('.rows strong', { hasText: '682 whp' })).toBeVisible();
  await shot(page, 'dyno-pull', info.project.name);
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
});

test('share link opens read-only and imports a plan', async ({ page }, info) => {
  await seed(page, 'dark');
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']).catch(() => undefined);
  await goto(page, '/planner');
  await page.evaluate(() => { (navigator as { share?: unknown }).share = undefined; });
  await page.getByRole('button', { name: 'Share plan as link' }).click();
  const url = await page.getByLabel('Share link').inputValue();
  expect(url).toMatch(/#\/share\/[A-Za-z0-9_-]+$/);
  await page.goto(url);
  await expect(page.getByRole('heading', { name: 'Shared build plan' })).toBeVisible();
  await shot(page, 'share-plan', info.project.name);
  await page.getByRole('button', { name: 'Import to my Build Planner' }).click();
  await expect(page.getByText('Plan added')).toBeVisible();
  const plans = await page.evaluate(() => JSON.parse(localStorage.getItem('gt500.plans.v1') || '[]'));
  expect(plans.map((p: { name: string }) => p.name)).toContain('Big (shared)');
  await page.goto('./#/share/not-valid!!');
  await expect(page.getByRole('alert')).toContainText(/damaged|read/);
});

test('home customization persists; year compare stacks on phones', async ({ page }, info) => {
  await seed(page, 'light');
  await goto(page, '/');
  await page.getByRole('button', { name: 'Customize Home' }).click();
  await page.getByRole('button', { name: 'Move Tools up' }).click();
  await page.getByRole('button', { name: 'Move Tools up' }).click();
  await page.getByRole('checkbox', { name: 'Confidence legend' }).uncheck();
  await shot(page, 'home-customize', info.project.name);
  await page.reload();
  await expect(page.locator('.dash-slot').first()).toContainText('Tools');
  await expect(page.locator('.legend')).toHaveCount(0);
  await goto(page, '/diff');
  const display = await page.locator('.tbl.diff tbody tr').first().evaluate((e) => getComputedStyle(e).display);
  expect(display).toBe(info.project.name === 'mobile' ? 'block' : 'table-row');
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  await shot(page, 'diff-stacked', info.project.name);
});

test('notifications: permission-gated toggle shows a due reminder', async ({ browser, baseURL }, info) => {
  const ctx = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 } });
  await ctx.grantPermissions(['notifications']);
  const page = await ctx.newPage();
  await page.addInitScript(() => {
    localStorage.setItem('gt500.onboarding.v1', JSON.stringify({ done: true, completed: '2026-01-01' }));
    localStorage.setItem('gt500.garage.v1', JSON.stringify({ odometer: '10900', reminders: [{ id: 'r1', item: 'Oil', everyMiles: 10000, everyMonths: null, lastMiles: 1000, lastDate: '' }] }));
    const shown: string[] = [];
    (window as unknown as { __shown: string[] }).__shown = shown;
    class N { static permission = 'granted'; static requestPermission = async () => 'granted'; constructor(t: string) { shown.push(t); } }
    (window as unknown as { Notification: unknown }).Notification = N;
    ServiceWorkerRegistration.prototype.showNotification = async function (t: string) { shown.push(t); };
  });
  await page.goto('./#/settings');
  await page.getByLabel(/Notify me/).check();
  await expect(page.getByRole('status').filter({ hasText: /On\./ })).toContainText('1 reminder');
  expect(await page.evaluate(() => (window as unknown as { __shown: string[] }).__shown)).toEqual(['Due soon: Oil']);
  await shot(page, 'settings-notify', info.project.name);
  await ctx.close();
});

test('parts catalog: search, copy to clipboard, linked from maintenance reminders', async ({ page, context }, info) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await seed(page, 'dark');
  await goto(page, '/garage');
  await page.locator('#maintenance').getByRole('link', { name: 'FL-2087' }).first().click();
  await expect(page).toHaveURL(/#\/parts\?q=FL-2087/);
  await expect(page.getByRole('heading', { name: 'Parts & Fluids' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Copy FL-2087' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Copy SP-581' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Copy FL-2087' }).click();
  await expect(page.getByRole('button', { name: 'Copy FL-2087' })).toHaveText('Copied');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('FL-2087');
  await page.getByLabel('Search parts').fill('coolant');
  await expect(page.getByRole('button', { name: 'Copy VC-13DL-G' })).toBeVisible();
  await shot(page, 'parts-search', info.project.name);
});

test('guide checklist ticks persist for the session', async ({ page }, info) => {
  await seed(page, 'light');
  await goto(page, '/guides');
  await page.getByRole('link', { name: /DCT fluid/ }).click();
  await expect(page.getByRole('heading', { name: /DCT fluid/ })).toBeVisible();
  const boxes = page.getByRole('checkbox');
  await boxes.nth(0).check(); await boxes.nth(2).check();
  await expect(page.getByText('2 of 4 done')).toBeVisible();
  await page.reload();
  await expect(page.getByText('2 of 4 done')).toBeVisible();
  await expect(boxes.nth(0)).toBeChecked();
  await shot(page, 'guide-dct', info.project.name);
  await page.getByRole('button', { name: 'Clear ticks' }).click();
  await expect(page.getByText('0 of 4 done')).toBeVisible();
});

test('language picker switches navigation and Settings to Spanish', async ({ page }, info) => {
  await seed(page, 'dark');
  await goto(page, '/settings');
  await page.getByRole('radio', { name: 'Español' }).click();
  await expect(page.getByRole('heading', { name: 'Ajustes', level: 1 })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('lang', 'es');
  await expect(page.getByRole('navigation', { name: 'Secciones' }).getByRole('link', { name: 'Piezas y fluidos' })).toHaveCount(1);
  const res = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(res.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  await shot(page, 'settings-es', info.project.name);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Ajustes', level: 1 })).toBeVisible();
  await page.getByRole('radio', { name: 'English' }).click();
  await expect(page.getByRole('heading', { name: 'Settings', level: 1 })).toBeVisible();
});

test('sources page downloads all facts as CSV and JSON', async ({ page }) => {
  await seed(page, 'dark');
  await goto(page, '/sources');
  const [csv] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download CSV' }).click()]);
  expect(csv.suggestedFilename()).toMatch(/^gt500-facts-\d{4}-\d{2}-\d{2}\.csv$/);
  const text = await (await import('node:fs/promises')).readFile((await csv.path())!, 'utf8');
  expect(text.split('\r\n')[0]).toBe('collection,id,path,label,value,source,originalUrl,confidence,note');
  expect(text).toContain('FL-2087');
  const [json] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'Download JSON' }).click()]);
  const data = JSON.parse(await (await import('node:fs/promises')).readFile((await json.path())!, 'utf8'));
  expect(data.count).toBeGreaterThan(300);
  expect(data.facts.every((f: { source: string; confidence: string }) => f.source && f.confidence !== undefined)).toBe(true);
});

test('hovering a menu link prefetches its route chunk', async ({ browser, baseURL }, info) => {
  // No service worker → no offline warm-up, so the only thing that can fetch the chunk is the prefetch.
  const ctx = await browser.newContext({ baseURL, serviceWorkers: 'block', ...(info.project.name === 'mobile' ? { viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true } : {}) });
  const page = await ctx.newPage();
  await seed(page, 'dark');
  await goto(page, '/');
  const requested: string[] = [];
  page.on('request', (r) => { if (r.url().includes('/assets/Quiz-')) requested.push(r.url()); });
  if (info.project.name === 'mobile') await page.getByRole('button', { name: 'Menu' }).click();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('link', { name: 'Trivia Quiz' }).hover();
  await expect.poll(() => requested.length).toBeGreaterThan(0);
  await ctx.close();
});
