/** Shorten text with an ellipsis until it fits `max` px (measure is ctx.measureText in the app). */
export function fitText(text: string, max: number, measure: (s: string) => number): string {
  if (measure(text) <= max) return text;
  let t = text;
  while (t.length > 1 && measure(t + '…') > max) t = t.slice(0, -1);
  return t + '…';
}

export interface CardData { title: string; year: string; colorName: string; swatch: string; modsCount: number; bestLap: string; bestLapTrack: string }

const BODY = 'M20 98 C22 80 40 74 70 70 L120 64 C150 40 190 30 236 32 C270 34 300 50 330 66 L372 74 C388 78 392 88 390 100 L386 108 L20 108 Z';

/** Draw a 1080×1080 spec card. Generic silhouette only — no logos or trademarks. */
export function drawShareCard(canvas: HTMLCanvasElement, d: CardData): void {
  const W = 1080;
  canvas.width = W; canvas.height = W;
  const c = canvas.getContext('2d');
  if (!c) return;
  const g = c.createLinearGradient(0, 0, 0, W);
  g.addColorStop(0, '#161a20'); g.addColorStop(1, '#0d0f12');
  c.fillStyle = g; c.fillRect(0, 0, W, W);
  c.fillStyle = '#e8463a'; c.fillRect(0, 0, W, 14);

  c.save();
  c.translate(90, 150); c.scale(2.25, 2.25);
  const body = new Path2D(BODY);
  c.fillStyle = 'rgba(0,0,0,.45)'; c.beginPath(); c.ellipse(205, 116, 190, 8, 0, 0, Math.PI * 2); c.fill();
  c.save(); c.clip(body);
  c.fillStyle = d.swatch; c.fillRect(0, 0, 400, 140);
  c.fillStyle = 'rgba(244,244,244,.9)'; c.fillRect(0, 62, 400, 7); c.fillRect(0, 74, 400, 7);
  c.restore();
  c.fillStyle = 'rgba(10,12,16,.85)'; c.fill(new Path2D('M136 64 C160 44 192 38 230 38 C258 39 282 50 304 64 Z'));
  for (const x of [104, 316]) { c.fillStyle = '#111'; c.beginPath(); c.arc(x, 106, 22, 0, Math.PI * 2); c.fill(); c.fillStyle = '#555'; c.beginPath(); c.arc(x, 106, 13, 0, Math.PI * 2); c.fill(); }
  c.restore();

  c.fillStyle = '#eceff3'; c.font = '800 64px system-ui, sans-serif';
  c.fillText(fitText(d.title || 'My GT500', W - 160, (x) => c.measureText(x).width), 80, 560);
  c.fillStyle = '#9aa3ae'; c.font = '600 34px system-ui, sans-serif';
  c.fillText(`${d.year || 'Year not set'} · 5.2L supercharged V8 · 7-speed DCT`, 80, 615);

  const rows: [string, string][] = [
    ['Color', d.colorName || 'Not set'],
    ['Mods logged', String(d.modsCount)],
    ['Best lap', d.bestLap ? `${d.bestLap}${d.bestLapTrack ? ` · ${d.bestLapTrack}` : ''}` : 'None logged'],
  ];
  rows.forEach(([k, v], i) => {
    const y = 720 + i * 90;
    c.fillStyle = '#1e232b'; c.fillRect(80, y - 58, W - 160, 76);
    c.fillStyle = '#9aa3ae'; c.font = '600 30px system-ui, sans-serif'; c.fillText(k, 110, y - 8);
    c.fillStyle = '#eceff3'; c.font = '700 34px system-ui, sans-serif';
    const fv = fitText(v, W - 400, (x) => c.measureText(x).width);
    const tw = c.measureText(fv).width; c.fillText(fv, W - 110 - tw, y - 8);
    if (i === 0) { c.fillStyle = d.swatch; c.fillRect(W - 150 - tw - 40, y - 42, 34, 34); }
  });
  c.fillStyle = '#6b7480'; c.font = '500 24px system-ui, sans-serif';
  c.fillText('Unofficial fan card · GT500 Companion · not affiliated with Ford or Shelby', 80, W - 50);
}
