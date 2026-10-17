/**
 * Optional accent colour from the active car's paint. The paint swatch's hue and saturation are kept and only the
 * lightness is moved until WCAG AA holds: accent text ≥ 4.5:1 against every page/card background of the theme, and
 * white button text ≥ 4.5:1 on the button colour. Near-grey paints (black, white, silver) and unknown colours fall
 * back to the default accent.
 */
export type Rgb = [number, number, number];

export function hexToRgb(hex: string): Rgb | null {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const h = m[1].length === 3 ? m[1].split('').map((c) => c + c).join('') : m[1];
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as Rgb;
}
export const rgbToHex = (c: Rgb) => `#${c.map((x) => Math.round(Math.max(0, Math.min(255, x))).toString(16).padStart(2, '0')).join('')}`;

/** WCAG 2.x relative luminance. */
export function luminance([r, g, b]: Rgb): number {
  const f = (v: number) => { const s = v / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}
export function contrast(a: Rgb, b: Rgb): number {
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

export function rgbToHsl([r, g, b]: Rgb): [number, number, number] {
  const R = r / 255, G = g / 255, B = b / 255;
  const max = Math.max(R, G, B), min = Math.min(R, G, B), l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === R ? (G - B) / d + (G < B ? 6 : 0) : max === G ? (B - R) / d + 2 : (R - G) / d + 4;
  return [h * 60, s, l];
}
export function hslToRgb([h, s, l]: [number, number, number]): Rgb {
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => { const k = (n + h / 30) % 12; return 255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))); };
  return [f(0), f(8), f(4)];
}

/** Page, card and raised-card backgrounds per theme (styles.css). */
export const THEME_BGS: Record<'dark' | 'light', string[]> = { dark: ['#0d0f12', '#161a20', '#1e232b'], light: ['#f4f5f7', '#ffffff', '#eef0f3'] };
export const AA = 4.5;
/** Paints less saturated than this are treated as neutral (no accent). */
export const MIN_SATURATION = 0.15;

export interface Accent { accent: string; accentBtn: string; textRatio: number; btnRatio: number }

/** Accent colours for a paint swatch, or null when the paint is neutral/unknown or AA cannot be met. */
export function deriveAccent(swatch: string | null | undefined, theme: 'dark' | 'light'): Accent | null {
  const rgb = swatch ? hexToRgb(swatch) : null;
  if (!rgb) return null;
  const [h, s, l0] = rgbToHsl(rgb);
  if (s < MIN_SATURATION) return null;
  const bgs = THEME_BGS[theme].map((x) => hexToRgb(x) as Rgb);
  const white: Rgb = [255, 255, 255];
  const minTo = (c: Rgb) => Math.min(...bgs.map((b) => contrast(c, b)));
  // Text accent: lighten on dark backgrounds, darken on light ones, in small steps from the paint's own lightness.
  let text: Rgb | null = null;
  for (let i = 0; i <= 100; i++) {
    const l = theme === 'dark' ? l0 + i * 0.01 : l0 - i * 0.01;
    if (l < 0 || l > 1) break;
    const c = hslToRgb([h, s, l]).map(Math.round) as Rgb;
    if (minTo(c) >= AA) { text = c; break; }
  }
  // Button: darken until white text passes.
  let btn: Rgb | null = null;
  for (let i = 0; i <= 100; i++) {
    const l = Math.min(l0, 0.6) - i * 0.01;
    if (l < 0) break;
    const c = hslToRgb([h, s, l]).map(Math.round) as Rgb;
    if (contrast(white, c) >= AA) { btn = c; break; }
  }
  if (!text || !btn) return null;
  return { accent: rgbToHex(text), accentBtn: rgbToHex(btn), textRatio: Math.round(minTo(text) * 100) / 100, btnRatio: Math.round(contrast(white, btn) * 100) / 100 };
}
