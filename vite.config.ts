import { defineConfig } from 'vitest/config';
import type { Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

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

/** Every file under `dir` (relative, POSIX separators), sorted. */
export function listFiles(dir: string, root = dir): string[] {
  return readdirSync(dir).flatMap((f) => { const p = join(dir, f); return statSync(p).isDirectory() ? listFiles(p, root) : [relative(root, p).split(sep).join('/')]; }).sort();
}

/**
 * Tooling only: write dist/.preview-manifest.json listing every emitted file with its size and SHA-256. The app
 * never reads it, and the service worker does not precache it (it is written after the worker is stamped).
 */
function previewManifest(): Plugin {
  let outDir = 'dist';
  return {
    name: 'preview-manifest',
    apply: 'build',
    configResolved(c) { outDir = c.build.outDir; },
    closeBundle() {
      if (!existsSync(outDir)) return;
      const name = '.preview-manifest.json';
      const files = listFiles(outDir).filter((f) => f !== name).map((path) => {
        const buf = readFileSync(join(outDir, path));
        return { path, bytes: buf.length, sha256: createHash('sha256').update(buf).digest('hex') };
      });
      writeFileSync(join(outDir, name), `${JSON.stringify({ generated: new Date().toISOString(), entry: 'index.html', count: files.length, files }, null, 2)}\n`);
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
  plugins: [react(), swVersion(), devCsp(), previewManifest()],
  base: './',
  test: { include: ['tests/**/*.test.{ts,tsx}'], setupFiles: ['tests/setup.ts'] },
});
