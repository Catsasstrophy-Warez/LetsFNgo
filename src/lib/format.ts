/**
 * Shared display/parse helpers for money. Every page and library used to define its own copy; they now share these
 * so rounding and separators stay identical everywhere. All amounts are USD and formatted en-US (sourced figures are
 * quoted in US dollars, and log values are what the owner typed).
 */

/** "$1,235" — whole dollars. */
export const usdWhole = (n: number) => `$${Math.round(n).toLocaleString('en-US')}`;
/** "$1,234.50" — fixed decimals (default 2). */
export const usdFixed = (n: number, d = 2) => `$${n.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d })}`;
/** "$1,000" or "$1,000–$1,500" when a range has two different ends (whole dollars). */
export const usdRange = (min: number, max: number) => (min === max ? usdWhole(min) : `${usdWhole(min)}–${usdWhole(max)}`);

/** Parse a typed amount ("$1,200", " 950 "). Empty, blank or unparseable → null. */
export function parseMoney(s: string | undefined): number | null {
  // A bare "$" or "," strips to "" (Number("") is 0), so require something left after stripping.
  const t = String(s ?? '').replace(/[$,\s]/g, '');
  const n = Number(t);
  return t && Number.isFinite(n) ? n : null;
}
