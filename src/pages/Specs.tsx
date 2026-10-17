import { specs } from '../data/specs';
import type { SpecSystem } from '../data/types';
import { Cite, Note, fmt } from '../components/Facts';
import { useLang, useT, useUnits } from '../components/SettingsContext';
import { specText } from '../data/es';
import { Link } from 'react-router';
import type { MsgKey } from '../lib/i18n';
import { convertSpec, type Units } from '../lib/units';
import type { SourcedValue } from '../data/types';

const show = (v: SourcedValue['value'], unit: string | undefined, u: Units) => { if (v === null) return fmt(v); const c = convertSpec(v, unit, u); return fmt(c.value, c.unit); };

const SYSTEMS: SpecSystem[] = ['Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy', 'Features'];

export default function Specs() {
  const u = useUnits();
  const t = useT();
  const lang = useLang();
  return (
    <>
      <h1>{t('nav.specs')}</h1>
      <p className="lede">{t('specs.lede')} <Link to="/settings">{t('specs.settingLink')}</Link> · <Link to="/print">{t('specs.printLink')}</Link></p>
      {SYSTEMS.map((sys) => (
        <section key={sys} className="card">
          <h2>{t(`sys.${sys}` as MsgKey)}</h2>
          <dl className="facts">
            {specs.filter((s) => s.system === sys).map((s) => { const tx = specText(s, lang); return (
              <div key={s.id} className={`fact ${s.value === null ? 'unknown' : ''}`}>
                <dt>{tx.label}{tx.translated && <> <span className="tag tag-tr" title={t('data.translatedTitle')}>{t('data.translated')}</span></>}</dt>
                <dd>
                  <span className="val">{show(s.value, s.unit, u)}</span> <Cite c={s.confidence} url={s.source} />
                  {s.conflicts && <><div className="conflict-tag">{t('common.sourcesDisagree')}</div><ul className="conflicts">{s.conflicts.map((v, i) => <li key={i}><strong>{show(v.value, s.unit, u)}</strong>{v.context && <span className="muted"> — {v.context}</span>} <Cite c={v.confidence} url={v.source} /></li>)}</ul></>}
                  {tx.note && <Note>{tx.note}</Note>}
                </dd>
              </div>
            ); })}
          </dl>
        </section>
      ))}
    </>
  );
}
