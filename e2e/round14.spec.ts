import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';

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

for (const theme of ['dark', 'light'] as const) {
  test(`Diagnostics: hidden under Settings → Advanced, opt-in, records OBD demo timings, exports anonymized JSON (${theme})`, async ({ page }) => {
    await seed(page, {}, 'en', theme);
    await goto(page, '/settings');
    await page.getByText('Advanced', { exact: true }).click();
    await page.getByRole('link', { name: 'Diagnostics →' }).click();
    await expect(page.getByRole('heading', { name: 'Diagnostics', level: 1 })).toBeVisible();
    await expect(page.getByText('Recording is off.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Export log (.json)' })).toBeDisabled();
    expect(await serious(page)).toEqual([]);
    await page.getByLabel('Record diagnostics while the Lap Timer and OBD-II pages run').check();
    await expect(page.getByText(/Recording is on/)).toBeVisible();
    await goto(page, '/obd');
    await page.getByRole('button', { name: 'Start demo (simulated data)' }).click();
    await expect(page.getByText('Demo — simulated').first()).toBeVisible();
    await page.waitForTimeout(1500);
    await page.getByRole('button', { name: 'Disconnect' }).click();
    await goto(page, '/diagnostics');
    await expect(page.getByText(/OBD 010C/).first()).toBeVisible();
    const dl = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Export log (.json)' }).click();
    const text = readFileSync((await (await dl).path())!, 'utf8');
    const j = JSON.parse(text);
    expect(j.app).toBe('gt500-companion-diagnostics');
    expect(j.summary.obd).toBeGreaterThan(0);
    expect(text).not.toMatch(/"lat"|"lon"|"t0"|"name"/);
    expect(await serious(page)).toEqual([]);
  });

  test(`Lap timer: Flip / Either direction for a sourced line, remembered per line (${theme})`, async ({ page }) => {
    await seed(page, {}, 'en', theme);
    await goto(page, '/laptimer');
    await page.getByLabel('Known track (optional)').selectOption('weathertech-raceway-laguna-seca');
    await page.getByRole('button', { name: 'Use sourced line' }).click();
    const group = page.getByRole('radiogroup', { name: 'Counted direction' });
    await expect(group.getByRole('radio', { name: 'As published' })).toHaveAttribute('aria-checked', 'true');
    await group.getByRole('radio', { name: 'Flip direction' }).click();
    await expect(page.getByText('Counting the opposite of the published direction.')).toBeVisible();
    expect(await serious(page)).toEqual([]);
    await page.reload();
    await expect(page.locator('main h1').first()).toBeVisible();
    await page.getByLabel('Known track (optional)').selectOption('weathertech-raceway-laguna-seca');
    await page.getByRole('button', { name: 'Use sourced line' }).click();
    await expect(page.getByRole('radio', { name: 'Flip direction' })).toHaveAttribute('aria-checked', 'true');
    await page.getByRole('radio', { name: 'Either direction' }).click();
    await expect(page.getByText('Both directions count; the first crossing sets it.')).toBeVisible();
  });

  test(`Specs in Spanish: translated labels carry a visible marker (${theme})`, async ({ page }) => {
    await seed(page, {}, 'es', theme);
    await goto(page, '/specs');
    await expect(page.locator('dt', { hasText: 'Potencia' })).toBeVisible();
    await expect(page.locator('.tag-tr').first()).toHaveText('traducido');
    expect(await serious(page)).toEqual([]);
  });
}
