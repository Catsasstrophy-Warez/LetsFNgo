// Render the SVG icon/splash sources to PNG with Playwright's Chromium (no logos; generic stripes + "760").
//   public/icon-maskable.svg → public/icon-maskable-{192,512}.png (full-bleed, content inside the 80 % safe zone)
//   resources/*.svg          → resources/*.png for `npx @capacitor/assets generate`
// Usage: node scripts/gen-assets.mjs
import { chromium } from 'playwright-core';
import { readFileSync } from 'node:fs';

const jobs = [
  ['public/icon-maskable.svg', 'public/icon-maskable-512.png', 512], ['public/icon-maskable.svg', 'public/icon-maskable-192.png', 192],
  ['resources/icon-only.svg', 'resources/icon-only.png', 1024], ['resources/icon-foreground.svg', 'resources/icon-foreground.png', 1024],
  ['resources/icon-background.svg', 'resources/icon-background.png', 1024], ['resources/splash.svg', 'resources/splash.png', 2732],
  ['resources/splash-dark.svg', 'resources/splash-dark.png', 2732],
];
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
try {
  for (const [src, out, size] of jobs) {
    const page = await browser.newPage({ viewport: { width: size, height: size } });
    const svg = readFileSync(src, 'utf8').replace('<svg ', `<svg width="${size}" height="${size}" `);
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await page.locator('svg').screenshot({ path: out, omitBackground: true });
    await page.close();
    console.log(out);
  }
} finally { await browser.close(); }
