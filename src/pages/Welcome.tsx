import { useState } from 'react';
import { useNavigate } from 'react-router';
import { colors } from '../data/colors';
import { useSettings, useT } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';
import { decodeVin } from '../lib/vin';
import { finishOnboarding, seedGarage } from '../lib/onboarding';
import type { Units } from '../lib/units';

const STEPS: MsgKey[] = ['welcome.s1', 'welcome.s2', 'welcome.s3'];

export default function Welcome() {
  const nav = useNavigate();
  const { settings, setSettings } = useSettings();
  const t = useT();
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
      <h1>{t('welcome.title')}</h1>
      <p className="lede">{t('welcome.lede')}</p>
      <ol className="steps" aria-label={t('welcome.progress')}>
        {STEPS.map((s, i) => <li key={s} className={i === step ? 'on' : i < step ? 'done' : ''} aria-current={i === step ? 'step' : undefined}>{i + 1}. {t(s)}</li>)}
      </ol>
      <section className="card" aria-labelledby="step-h">
        <h2 id="step-h">{t('welcome.step', { n: step + 1, name: t(STEPS[step]) })}</h2>
        {step === 0 && (
          <div className="form">
            <label>{t('garage.year')}
              <select className="input" value={year} onChange={(e) => { setYear(e.target.value); setColor(''); }}>
                <option value="">{t('welcome.notSure')}</option><option value="2020">2020</option><option value="2021">2021</option><option value="2022">2022</option>
              </select>
            </label>
            <fieldset className="swatch-picker">
              <legend>{t('garage.color')}{year && ` ${t('welcome.sourcedFor', { y: year })}`}</legend>
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
            <label>VIN<input className="input mono" value={vin} onChange={(e) => setVin(e.target.value)} maxLength={17} autoCapitalize="characters" spellCheck={false} placeholder={t('welcome.vinPh')} /></label>
            {v && (v.valid
              ? <p className="ok-t" role="status">{t('welcome.vinOk')}{v.isGT500 ? ` · ${t('welcome.gt500')}` : ''}{v.year ? ` · ${v.year}` : ''}.</p>
              : <p className="warn-t" role="status">{v.errors[0] ?? t('welcome.vinBad')} {t('welcome.vinNotSaved')}</p>)}
            <p className="muted small">{t('welcome.vinLocal')}</p>
          </div>
        )}
        {step === 2 && (
          <div role="radiogroup" aria-label={t('settings.units')} className="seg">
            {([['imperial', t('settings.imperial')], ['metric', t('settings.metric')]] as [Units, string][]).map(([k, l]) => (
              <button key={k} role="radio" aria-checked={units === k} className={units === k ? 'on' : ''} onClick={() => setUnits(k)}>{l}</button>
            ))}
          </div>
        )}
        {step === 2 && <p className="muted small">{t('welcome.moreCars')}</p>}
        <div className="btn-row">
          {step > 0 && <button className="btn ghost" onClick={() => setStep(step - 1)}>{t('common.back')}</button>}
          {step < 2 ? <button className="btn" onClick={() => setStep(step + 1)}>{t('common.next')}</button> : <button className="btn" onClick={done}>{t('common.finish')}</button>}
          <button className="link-btn" onClick={skip}>{t('welcome.skip')}</button>
        </div>
      </section>
    </>
  );
}
