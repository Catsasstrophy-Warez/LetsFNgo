#!/usr/bin/env node
/**
 * npm run validate:data — checks every record in src/data against schemas/*.schema.json rules
 * (shape, https source, confidence enum, null-needs-note, no duplicates, conflict structure).
 * --write-schemas regenerates schemas/ from src/lib/dataSchema.ts. Exits 1 on any problem.
 */
import { createServer } from 'vite';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const server = await createServer({ root, configFile: false, logLevel: 'error', server: { middlewareMode: true, hmr: false, watch: null }, appType: 'custom', optimizeDeps: { noDiscovery: true, include: [] } });
let code = 0;
try {
  const { SCHEMAS, checkCollections } = await server.ssrLoadModule('/src/lib/dataSchema.ts');
  const { collections } = await server.ssrLoadModule('/src/data/index.ts');
  const dir = join(root, 'schemas');
  if (process.argv.includes('--write-schemas')) {
    mkdirSync(dir, { recursive: true });
    for (const [name, s] of Object.entries(SCHEMAS)) writeFileSync(join(dir, `${name}.schema.json`), JSON.stringify(s, null, 2) + '\n');
    console.log(`Wrote ${Object.keys(SCHEMAS).length} schemas to schemas/`);
  }
  for (const name of Object.keys(SCHEMAS)) {
    const f = join(dir, `${name}.schema.json`);
    if (!existsSync(f) || readFileSync(f, 'utf8') !== JSON.stringify(SCHEMAS[name], null, 2) + '\n') {
      console.error(`schemas/${name}.schema.json is missing or out of date — run: npm run validate:data -- --write-schemas`);
      code = 1;
    }
  }
  const issues = checkCollections(collections);
  const n = Object.values(collections).reduce((a, r) => a + r.length, 0);
  for (const i of issues) console.error(`✗ ${i.collection} ${i.path}: ${i.message}`);
  if (issues.length) { console.error(`\n${issues.length} problem(s) in ${n} records.`); code = 1; }
  else console.log(`✓ ${n} records in ${Object.keys(collections).length} collections are valid.`);
} finally {
  await server.close();
}
process.exit(code);
