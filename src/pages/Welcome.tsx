import { useState } from 'react';
import { useNavigate } from 'react-router';
import { colors } from '../data/colors';
import { useSettings } from '../components/SettingsContext';
import { decodeVin } from '../lib/vin';
import { finishOnboarding, seedGarage } from '../lib/onboarding';
import type { Units } from '../lib/units';

const STEPS = ['Your car', 'VIN (optional)', 'Units'];

export default function Welcome() {
  const nav = useNavigate();
  const { settings, setSettings } = useSettings();
  const [step, setStep] = useState(0);
  const [year, setYear] = useState('');
  const [color, setColor] = useState('');
  const [vin, setVin] = useState('');
  const [units, setUnits] = useState<Units>(settings.units);
  const yearColors = colors.filter((c) => !year || c.years.includes(Number(year) as 2020));
  const v = vin.trim() ? decodeVin(vin) : null;

  const skip = () => { finishOnboarding(); nav('/', { replace: true }); };
  const done = () => {
    seedGarage({ year, color, vin: v && v.valid ? v.vin : '' });
    setSettings({ ...settings, units });
    finishOnboarding();
    nav('/garage', { replace: true });
  };

  return (
    <>
      <h1>Welcome</h1>
      <p className="lede">Three quick questions set up your Garage. Everything stays on this device. You can skip and change any of it later in Garage and Settings.</p>
      <ol className="steps" aria-label="Progress">
        {STEPS.map((s, i) => <li key={s} className={i === step ? 'on' : i < step ? 'done' : ''} aria-current={i === step ? 'step' : undefined}>{i + 1}. {s}</li>)}
      </ol>
      <section className="card" aria-labelledby="step-h">
        <h2 id="step-h">Step {step + 1} of 3: {STEPS[step]}</h2>
        {step === 0 && (
          <div className="form">
            <label>Model year
              <select className="input" value={year} onChange={(e) => { setYear(e.target.value); setColor(''); }}>
                <option value="">Not sure</option><option value="2020">2020</option><option value="2021">2021</option><option value="2022">2022</option>
              </select>
            </label>
            <fieldset className="swatch-picker">
              <legend>Color{year && ` (sourced for ${year})`}</legend>
              {yearColors.map((c) => (
                <button key={c.id} type="button" className="swatch-btn" aria-pressed={color === c.id} onClick={() => setColor(color === c.id ? '' : c.id)} title={c.name}>
                  <span className="dot" style={{ background: c.swatch }} aria-hidden /> {c.name}
                </button>
              ))}
            </fieldset>
          </div>
        )}
        {step === 1 && (
          <div className="form">
            <label>VIN<input className="input mono" value={vin} onChange={(e) => setVin(e.target.value)} maxLength={17} autoCapitalize="characters" spellCheck={false} placeholder="17 characters (optional)" /></label>
            {v && (v.valid
              ? <p className="ok-t" role="status">Valid check digit{v.isGT500 ? ' · GT500 pattern' : ''}{v.year ? ` · ${v.year}` : ''}.</p>
              : <p className="warn-t" role="status">{v.errors[0] ?? 'Check digit does not match.'} It will not be saved unless it is valid.</p>)}
            <p className="muted small">The VIN is only checked on this device; nothing is sent anywhere.</p>
          </div>
        )}
        {step === 2 && (
          <div role="radiogroup" aria-label="Units" className="seg">
            {([['imperial', 'Imperial (mi, mph, lb, °F)'], ['metric', 'Metric (km, km/h, kg, °C)']] as [Units, string][]).map(([k, l]) => (
              <button key={k} role="radio" aria-checked={units === k} className={units === k ? 'on' : ''} onClick={() => setUnits(k)}>{l}</button>
            ))}
          </div>
        )}
        <div className="btn-row">
          {step > 0 && <button className="btn ghost" onClick={() => setStep(step - 1)}>Back</button>}
          {step < 2 ? <button className="btn" onClick={() => setStep(step + 1)}>Next</button> : <button className="btn" onClick={done}>Finish</button>}
          <button className="link-btn" onClick={skip}>Skip intro</button>
        </div>
      </section>
    </>
  );
}
