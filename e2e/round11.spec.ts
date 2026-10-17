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

/** Fake geolocation: a 300 m circle at 40 m/s, one fix per simulated second. Holds after 3 fixes until window.__go. */
async function fakeGps(page: Page) {
  await page.addInitScript(() => {
    const w = window as unknown as { __go?: boolean };
    const R = 6371008.8, lat0 = 36.584, lon0 = -121.753, k = Math.cos((lat0 * Math.PI) / 180);
    const at = (i: number) => {
      const a = -Math.PI / 2 + (40 * i) / 300; // starts on the south side, anticlockwise
      return { lat: lat0 + ((300 * Math.sin(a)) / R) * (180 / Math.PI), lon: lon0 + ((300 * Math.cos(a)) / (R * k)) * (180 / Math.PI) };
    };
    const geo = {
      watchPosition(ok: PositionCallback) {
        let i = 0;
        const id = window.setInterval(() => {
          if (i >= 3 && !w.__go) return;
          if (i > 150) return;
          const p = at(i);
          ok({ timestamp: 1_700_000_000_000 + i * 1000, coords: { latitude: p.lat, longitude: p.lon, accuracy: 4, speed: 40, altitude: null, altitudeAccuracy: null, heading: null, toJSON() { return this; } }, toJSON() { return this; } } as unknown as GeolocationPosition);
          i++;
        }, 15);
        return id;
      },
      clearWatch(id: number) { window.clearInterval(id); },
      getCurrentPosition(ok: PositionCallback) { ok({ timestamp: Date.now(), coords: { latitude: 36.58, longitude: -121.75, accuracy: 20, speed: null } } as unknown as GeolocationPosition); },
    };
    Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true });
  });
}

test('GPS lap timer: drop line, time laps, auto-save to Track log with analysis', async ({ page }, info) => {
  await seed(page);
  await fakeGps(page);
  await goto(page, '/laptimer');
  await expect(page.getByRole('button', { name: 'Start GPS' })).toBeVisible();
  expect(await serious(page)).toEqual([]);
  await page.getByRole('button', { name: 'Start GPS' }).click();
  await expect(page.getByText(/Nearest known facility: WeatherTech Raceway Laguna Seca/)).toBeVisible();
  await page.waitForTimeout(150);
  await page.getByRole('button', { name: 'Drop line here' }).click();
  await expect(page.getByText(/Line set/)).toBeVisible();
  await page.evaluate(() => { (window as unknown as { __go: boolean }).__go = true; });
  await expect(page.locator('.hl ol.rows li').nth(1)).toBeVisible({ timeout: 10000 });
  await expect(page.locator('.hl ol.rows li').nth(1)).toContainText('0:47.1');
  await shot(page, 'laptimer-live', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.getByRole('button', { name: 'Stop & save' }).click();
  await expect(page.getByText(/Session saved to the Track log \(\d valid laps\)/)).toBeVisible();
  await goto(page, '/track');
  await expect(page.getByText('GPS analysis')).toBeVisible();
  await expect(page.getByRole('figure').filter({ hasText: 'Speed vs distance' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Export GPX' })).toBeEnabled();
  await page.locator('.lap-pick input:not(:checked)').first().check();
  await expect(page.locator('.ga-line')).toHaveCount(2);
  await shot(page, 'track-gps-analysis', info.project.name);
  expect(await serious(page)).toEqual([]);
});

test('weather auto-fill: opt-in, mocked Open-Meteo, offline-safe', async ({ page }, info) => {
  await seed(page);
  let calls = 0;
  await page.route('https://api.open-meteo.com/**', (r) => { calls++; return r.fulfill({ contentType: 'application/json', body: JSON.stringify({ elevation: 75, current_units: { temperature_2m: '°F' }, current: { time: '2026-06-01T12:00', temperature_2m: 68.4, relative_humidity_2m: 55, surface_pressure: 1003.2, pressure_msl: 1012.4 } }) }); });
  await goto(page, '/drag');
  const da = page.locator('section[aria-labelledby="da-h"]');
  await expect(da.getByRole('button', { name: 'Fetch weather' })).toHaveCount(0);
  await da.getByLabel(/Fill from current weather/).check();
  await da.getByLabel('Latitude').fill('36.58');
  await da.getByLabel('Longitude').fill('-121.75');
  await da.getByRole('button', { name: 'Fetch weather' }).click();
  await expect(da.getByText(/Filled from Open-Meteo/)).toBeVisible();
  expect(calls).toBe(1);
  await expect(da.getByRole('checkbox', { name: /station/i }).first()).toBeChecked();
  await shot(page, 'drag-weather', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.route('https://api.open-meteo.com/**', (r) => r.abort());
  await da.getByRole('button', { name: 'Fetch weather' }).click();
  await expect(da.getByText(/Could not reach Open-Meteo/)).toBeVisible();
});

test('search: fuzzy, grouped, keyboard navigation and recent searches', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/search');
  await page.getByRole('searchbox').fill('fl2087');
  await expect(page.locator('.search-group').first()).toBeVisible();
  await page.getByRole('searchbox').press('ArrowDown');
  await expect(page.locator('a.hit-link').first()).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowUp');
  await page.keyboard.press('ArrowUp');
  await expect(page.getByRole('searchbox')).toBeFocused();
  await page.getByRole('searchbox').fill('whiple');
  await expect(page.getByText(/\d+ results?/)).toBeVisible();
  await shot(page, 'search-fuzzy', info.project.name);
  expect(await serious(page)).toEqual([]);
  await page.getByRole('searchbox').press('Enter');
  await expect(page).toHaveURL(/#\/mods/);
  expect(await page.evaluate(() => localStorage.getItem('gt500.recentSearches.v1'))).toContain('whiple');
  await goto(page, '/search');
  await page.getByRole('searchbox').fill('');
  await expect(page.getByRole('button', { name: 'whiple' })).toBeVisible();
  await page.getByRole('button', { name: 'whiple' }).click();
  await expect(page.getByRole('searchbox')).toHaveValue('whiple');
});

for (const lang of ['en', 'es'] as const) {
  test(`new pages axe clean in light theme (${lang})`, async ({ page }) => {
    await seed(page, lang, 'light');
    for (const r of ['/laptimer', '/sources', '/compare', '/dyno']) { await goto(page, r); expect(await serious(page), r).toEqual([]); }
  });
}
