import { useState } from 'react';
import { fromDisplay, toDisplay, unitLabel, type Kind } from '../lib/units';
import { useUnits } from './SettingsContext';

const show = (kind: Kind | null, v: number | null, u: ReturnType<typeof useUnits>, digits: number) =>
  v === null ? '' : String(Number((kind ? toDisplay(kind, v, u) : v).toFixed(digits)));

/**
 * Numeric input bound to an imperial base value. Shows and accepts the chosen units; keeps the typed text
 * while focused so conversions never fight the cursor.
 */
export function UnitInput({ label, kind, value, onChange, digits = 2, hint }: {
  label: string; kind: Kind | null; value: number | null; onChange: (v: number | null) => void; digits?: number; hint?: string;
}) {
  const u = useUnits();
  const [draft, setDraft] = useState<string | null>(null);
  const text = draft ?? show(kind, value, u, digits);
  return (
    <label>{label}{kind && ` (${unitLabel(kind, u)})`}
      <input className="input" inputMode="decimal" value={text} placeholder={hint}
        onFocus={() => setDraft(text)} onBlur={() => setDraft(null)}
        onChange={(e) => {
          setDraft(e.target.value);
          const s = e.target.value.trim().replace(/,/g, '');
          const n = Number(s);
          onChange(s === '' || !Number.isFinite(n) ? null : kind ? fromDisplay(kind, n, u) : n);
        }} />
    </label>
  );
}
