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

export default defineConfig({
  plugins: [react(), swVersion()],
  base: './',
  test: { include: ['tests/**/*.test.{ts,tsx}'] },
});
