#!/usr/bin/env node
// Compares two build manifests (dist/.preview-manifest.json) and prints which
// files a static-host deploy must upload and which stale ones it can delete.
// Hashed asset names change every build, so hosts that keep old files fill up.
//
// Usage: node scripts/preview-diff.mjs <previous-manifest.json> [current-manifest.json]
import { readFileSync } from 'node:fs';

const [prevPath, currPath = 'dist/.preview-manifest.json'] = process.argv.slice(2);
if (!prevPath) {
  console.error('Usage: node scripts/preview-diff.mjs <previous-manifest.json> [current-manifest.json]');
  process.exit(2);
}

function load(path) {
  const manifest = JSON.parse(readFileSync(path, 'utf8'));
  if (!Array.isArray(manifest.files)) throw new Error(`${path}: missing "files" array`);
  return new Map(manifest.files.map((f) => [f.path, f.sha256]));
}

const prev = load(prevPath);
const curr = load(currPath);

const upload = [...curr].filter(([path, hash]) => prev.get(path) !== hash).map(([path]) => path);
const remove = [...prev.keys()].filter((path) => !curr.has(path));
const unchanged = curr.size - upload.length;

console.log(JSON.stringify({ upload, remove, unchanged }, null, 2));
