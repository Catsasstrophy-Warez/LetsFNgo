import { defineConfig } from 'vitest/config';
import type { Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

/** Stamp dist/sw.js with a per-build version and the list of emitted assets to precache. */
function swVersion(): Plugin {
  let outDir = 'dist';
  let files: string[] = [];
  return {
    name: 'sw-version',
    apply: 'build',
    configResolved(c) { outDir = c.build.outDir; },
    generateBundle(_o, bundle) { files = Object.keys(bundle).filter((f) => !f.endsWith('.map') && f !== 'index.html'); },
    writeBundle() {
      const p = join(outDir, 'sw.js');
      if (!existsSync(p)) return;
      const hash = createHash('sha256').update(files.sort().join('|')).update(readFileSync(join(outDir, 'index.html'))).digest('hex').slice(0, 12);
      const src = readFileSync(p, 'utf8').replace("'__BUILD__'", `'${hash}'`).replace('/*__ASSETS__*/', files.map((f) => `, './${f}'`).join(''));
      writeFileSync(p, src);
    },
  };
}

/**
 * Dev server only: Vite injects CSS as <style> tags (and React refresh as an inline script), which the strict CSP
 * blocks, so `npm run dev` (and the /dev/gallery page) rendered unstyled. Production builds keep the strict CSP.
 */
function devCsp(): Plugin {
  return {
    name: 'dev-csp',
    apply: 'serve',
    transformIndexHtml: (html) => html.replace("style-src 'self'", "style-src 'self' 'unsafe-inline'").replace("script-src 'self'", "script-src 'self' 'unsafe-inline'").replace("connect-src 'self'", "connect-src 'self' ws: wss:"),
  };
}

export default defineConfig({
  plugins: [react(), swVersion(), devCsp()],
  base: './',
  test: { include: ['tests/**/*.test.{ts,tsx}'], setupFiles: ['tests/setup.ts'] },
});
