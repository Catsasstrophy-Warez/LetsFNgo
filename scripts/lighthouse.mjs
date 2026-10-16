// Lighthouse (mobile preset, the CLI default) against the production build served by `vite preview`.
// Usage: npm run build && npm run lighthouse [-- /route ...]
// Needs Chromium: set CHROME_PATH (defaults to the Playwright build at /opt/pw-browsers) and network access for `npx lighthouse`.
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, existsSync } from 'node:fs';

const chrome = process.env.CHROME_PATH || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome';
if (!existsSync(chrome)) { console.error(`Chromium not found at ${chrome}; set CHROME_PATH.`); process.exit(1); }
const routes = process.argv.slice(2).length ? process.argv.slice(2) : ['/', '/specs', '/parts', '/guides/track-service', '/sources'];
const port = 4175;
const server = spawn('npx', ['vite', 'preview', '--port', String(port), '--strictPort', '--host', '127.0.0.1'], { stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 2500));
mkdirSync('.lighthouse', { recursive: true });
const rows = [];
try {
  for (const r of routes) {
    const name = r === '/' ? 'home' : r.replace(/\//g, '_').replace(/^_/, '');
    const out = `.lighthouse/${name}.json`;
    execFileSync('npx', ['-y', 'lighthouse@12', `http://127.0.0.1:${port}/#${r}`, '--quiet', '--output=json', `--output-path=${out}`,
      `--chrome-path=${chrome}`, '--chrome-flags=--headless=new --no-sandbox', '--only-categories=performance,accessibility,best-practices,seo'], { stdio: 'inherit', env: { ...process.env, CHROME_PATH: chrome } });
    const j = JSON.parse(readFileSync(out, 'utf8'));
    const s = (k) => Math.round(j.categories[k].score * 100);
    rows.push({ route: r, performance: s('performance'), accessibility: s('accessibility'), 'best-practices': s('best-practices'), seo: s('seo'),
      LCP: j.audits['largest-contentful-paint'].displayValue, TBT: j.audits['total-blocking-time'].displayValue, CLS: j.audits['cumulative-layout-shift'].displayValue });
  }
} finally { server.kill(); }
console.table(rows);
