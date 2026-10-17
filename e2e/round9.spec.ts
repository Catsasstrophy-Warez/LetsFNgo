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
/** Record any CSP violation the page reports. */
async function watchCsp(page: Page) {
  await page.addInitScript(() => { (window as unknown as { __csp: string[] }).__csp = []; document.addEventListener('securitypolicyviolation', (e) => (window as unknown as { __csp: string[] }).__csp.push(`${e.violatedDirective} ${e.blockedURI}`)); });
  return () => page.evaluate(() => (window as unknown as { __csp: string[] }).__csp);
}

test('strict CSP (no unsafe-inline styles): pages render with no violations', async ({ page }) => {
  await seed(page);
  const csp = await watchCsp(page);
  for (const r of ['/', '/market', '/garage', '/dyno', '/editions', '/history', '/parts?tab=fp', '/help', '/visualizer']) {
    await goto(page, r);
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  }
  expect(await csp()).toEqual([]);
});

test('custom install prompt: shows on beforeinstallprompt, "Not now" is remembered', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/');
  await expect(page.getByRole('button', { name: 'Install' })).toHaveCount(0);
  await page.evaluate(() => { const e = new Event('beforeinstallprompt', { cancelable: true }); Object.assign(e, { prompt: async () => undefined, userChoice: Promise.resolve({ outcome: 'dismissed' }) }); window.dispatchEvent(e); });
  await expect(page.getByText('Install GT500 Companion')).toBeVisible();
  await shot(page, 'install-prompt', info.project.name);
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical')).toEqual([]);
  await page.getByRole('button', { name: 'Not now' }).click();
  await expect(page.getByText('Install GT500 Companion')).toHaveCount(0);
  expect(JSON.parse((await page.evaluate(() => localStorage.getItem('gt500.install.v1')))!).dismissed).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  await page.reload();
  await page.evaluate(() => { const e = new Event('beforeinstallprompt', { cancelable: true }); Object.assign(e, { prompt: async () => undefined, userChoice: Promise.resolve({ outcome: 'accepted' }) }); window.dispatchEvent(e); });
  await expect(page.getByText('Install GT500 Companion')).toHaveCount(0);
});

test('iOS Safari gets an Add to Home Screen hint', async ({ browser }, info) => {
  const ctx = await browser.newContext({ userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1', viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  await seed(page);
  await goto(page, '/');
  await expect(page.getByText(/Add to Home Screen/)).toBeVisible();
  await shot(page, 'ios-hint', info.project.name);
  await ctx.close();
});

test('Parts: Ford Performance tab with keyboard switching, filters and fitment caveat', async ({ page }, info) => {
  await seed(page);
  await goto(page, '/parts');
  await page.getByRole('tab', { name: 'Parts & fluids' }).focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'Ford Performance' })).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByRole('tab', { name: 'Ford Performance' })).toBeFocused();
  await expect(page).toHaveURL(/tab=fp/);
  await expect(page.getByText('18 of 18 parts')).toBeVisible();
  await page.getByLabel('Only parts the catalog lists for the 2020–22 GT500').check();
  await expect(page.getByText('6 of 18 parts')).toBeVisible();
  await page.getByLabel('Search parts').fill('m6766');
  await expect(page.getByText('1 of 18 parts')).toBeVisible();
  await shot(page, 'parts-fp', info.project.name);
});

test('Editions filters and History timeline (Spanish)', async ({ page }, info) => {
  await seed(page, 'es', 'light');
  await goto(page, '/editions');
  await expect(page.getByRole('heading', { name: 'Ediciones de Shelby American' })).toBeVisible();
  await expect(page.getByText('3 de 3 ediciones')).toBeVisible();
  await page.getByLabel(/no son legales para la calle/).check();
  await expect(page.getByText('2 de 3 ediciones')).toBeVisible();
  await shot(page, 'editions-es', info.project.name);
  await goto(page, '/history');
  await page.getByRole('button', { name: 'Hitos' }).click();
  await expect(page.getByText('SAAC-46')).toHaveCount(0);
  await expect(page.getByText(/NAIAS/)).toBeVisible();
  await shot(page, 'history-es', info.project.name);
});

test('Help page and manifest shortcuts', async ({ page, request }) => {
  await seed(page);
  await goto(page, '/help');
  await expect(page.getByRole('heading', { name: 'Data privacy' })).toBeVisible();
  const m = await (await request.get('./manifest.webmanifest')).json();
  expect(m.shortcuts).toHaveLength(3);
  for (const i of m.icons) expect((await request.get(`./${i.src}`)).ok()).toBe(true);
});
