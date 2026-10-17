import { defineConfig } from '@playwright/test';

/** E2E + accessibility (axe-core) against the production build. Run: npm run e2e */
export default defineConfig({
  testDir: 'e2e',
  timeout: 60_000,
  fullyParallel: true,
  reporter: [['list']],
  // Visual regression baselines (e2e/visual.spec.ts) are platform-independent paths; update with `npm run e2e:update-visual`.
  snapshotPathTemplate: '{testDir}/__screenshots__/{testFileName}/{arg}{ext}',
  expect: { toHaveScreenshot: { maxDiffPixelRatio: 0.03, threshold: 0.25, animations: 'disabled', caret: 'hide', scale: 'css' } },
  use: { baseURL: 'http://127.0.0.1:4173/', browserName: 'chromium' },
  projects: [
    { name: 'mobile', use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
    { name: 'desktop', use: { viewport: { width: 1280, height: 800 } } },
  ],
  webServer: { command: 'npx vite preview --port 4173 --strictPort --host 127.0.0.1', url: 'http://127.0.0.1:4173/', reuseExistingServer: true, timeout: 60_000 },
});
