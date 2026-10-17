import { useState } from 'react';
import { formatUnitInput, parseUnitInput, unitLabel, type Kind } from '../lib/units';
import { useUnits } from './SettingsContext';

const show = formatUnitInput;

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
          onChange(parseUnitInput(kind, e.target.value, u));
        }} />
    </label>
  );
}
