#!/usr/bin/env node
/**
 * npm run check:links — HEAD (falling back to GET) every unique source URL in src/data with timeouts and retries,
 * and write link-report/links.json + link-report/links.md. Statuses: ok (2xx), redirect (3xx), 4xx, 5xx,
 * blocked (401/403/429/451/999 bot walls or a proxy/policy denial), error (timeout / DNS / TLS).
 * Never exits non-zero for broken links (it is a report, not a gate); exits 1 only if it cannot run at all.
 * Options: --out <dir> (default link-report), --concurrency <n> (6), --timeout <ms> (15000), --retries <n> (2).
 */
import { createServer } from 'vite';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// Node 22.21+/24 honor HTTPS_PROXY for fetch only with NODE_USE_ENV_PROXY=1; re-run once with it set.
if ((process.env.HTTPS_PROXY || process.env.https_proxy) && !process.env.NODE_USE_ENV_PROXY) {
  const r = spawnSync(process.execPath, process.argv.slice(1), { stdio: 'inherit', env: { ...process.env, NODE_USE_ENV_PROXY: '1' } });
  process.exit(r.status ?? 1);
}

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(root, arg('out', 'link-report'));
const CONC = Number(arg('concurrency', 6)), TIMEOUT = Number(arg('timeout', 15000)), RETRIES = Number(arg('retries', 2));
const UA = 'Mozilla/5.0 (compatible; GT500CompanionLinkCheck/1.0; +https://github.com/Catsasstrophy-Warez/LetsFNgo)';
const BLOCKED = new Set([401, 403, 429, 451, 999]);

const server = await createServer({ root, configFile: false, logLevel: 'error', server: { middlewareMode: true, hmr: false, watch: null }, appType: 'custom', optimizeDeps: { noDiscovery: true, include: [] } });
let urls;
try { urls = (await server.ssrLoadModule('/src/data/index.ts')).allSourceUrls(); } finally { await server.close(); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function once(url, method) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT);
  try {
    const res = await fetch(url, { method, redirect: 'manual', signal: ctl.signal, headers: { 'user-agent': UA, accept: 'text/html,application/xhtml+xml,*/*;q=0.8' } });
    if (method === 'GET') res.body?.cancel().catch(() => undefined);
    return { code: res.status, location: res.headers.get('location'), proxyDenied: res.headers.get('x-agentproxy-denied') !== null };
  } finally { clearTimeout(t); }
}
function classify(code) {
  if (code >= 200 && code < 300) return 'ok';
  if (code >= 300 && code < 400) return 'redirect';
  if (BLOCKED.has(code)) return 'blocked';
  if (code >= 400 && code < 500) return '4xx';
  return '5xx';
}
async function check(url) {
  let last = { url, status: 'error', code: null, detail: '' };
  for (let attempt = 0; attempt <= RETRIES; attempt++) {
    if (attempt) await sleep(800 * 2 ** (attempt - 1));
    try {
      let r = await once(url, 'HEAD');
      // Many servers reject or mis-answer HEAD; confirm anything that is not 2xx/3xx with a GET.
      if (r.code >= 400) r = await once(url, 'GET');
      const status = r.proxyDenied ? 'blocked' : classify(r.code);
      last = { url, status, code: r.code, detail: status === 'redirect' && r.location ? new URL(r.location, url).href : '' };
      if (status !== '5xx') return last;
    } catch (e) {
      const msg = e?.name === 'AbortError' || /cancel/i.test(String(e?.message)) ? `timeout after ${TIMEOUT} ms` : String(e?.cause?.code || e?.cause?.message || e?.message || e);
      last = { url, status: /ECONNRESET|403|407|tunnel/i.test(msg) ? 'blocked' : 'error', code: null, detail: msg };
    }
  }
  return last;
}

const results = new Array(urls.length);
let next = 0;
await Promise.all(Array.from({ length: Math.min(CONC, urls.length) }, async () => {
  while (next < urls.length) { const i = next++; results[i] = await check(urls[i]); process.stdout.write('.'); }
}));
process.stdout.write('\n');

const order = ['ok', 'redirect', '4xx', '5xx', 'blocked', 'error'];
const summary = Object.fromEntries(order.map((s) => [s, results.filter((r) => r.status === s).length]));
const report = { checkedAt: new Date().toISOString(), total: urls.length, summary, results };
mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'links.json'), JSON.stringify(report, null, 2) + '\n');
const md = [`# Source link check`, '', `Checked ${urls.length} unique source URLs at ${report.checkedAt}.`, '',
  '| Status | Count |', '|---|---|', ...order.map((s) => `| ${s} | ${summary[s]} |`), '',
  ...order.filter((s) => s !== 'ok' && summary[s]).flatMap((s) => [`## ${s}`, '', ...results.filter((r) => r.status === s).map((r) => `- ${r.url} — ${r.code ?? ''} ${r.detail}`.trim()), '']),
].join('\n');
writeFileSync(join(OUT, 'links.md'), md + '\n');
console.log(order.map((s) => `${s}: ${summary[s]}`).join('  '));
console.log(`Report: ${join(OUT, 'links.md')}`);
