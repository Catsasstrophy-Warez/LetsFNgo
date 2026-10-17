import { specs } from '../data/specs';
import { colors } from '../data/colors';
import type { SpecSystem } from '../data/types';
import { Badge, fmt, hostOf } from '../components/Facts';
import { useT, useUnits } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';
import { convertSpec, fmtQty } from '../lib/units';
import { loadGarage, toNum } from '../lib/garage';

const SYSTEMS: SpecSystem[] = ['Engine', 'Drivetrain', 'Chassis & Brakes', 'Wheels & Tires', 'Dimensions & Weight', 'Fuel & Economy'];

export default function PrintSheet() {
  const u = useUnits();
  const t = useT();
  const g = loadGarage();
  const color = colors.find((c) => c.id === g.color);
  return (
    <article className="print-sheet">
      <div className="no-print btn-row">
        <button className="btn" onClick={() => window.print()}>{t('print.btn')}</button>
        <span className="muted small">{t('print.hint')}</span>
      </div>
      <h1>{t('print.title')}</h1>
      <section className="print-car">
        <h2>{g.nickname || t('home.myCar')}</h2>
        <dl className="facts compact">
          <div className="fact"><dt>{t('common.year')}</dt><dd>{g.year || '—'}</dd></div>
          <div className="fact"><dt>{t('garage.color')}</dt><dd>{color ? `${color.name}${color.code ? ` (${color.code})` : ''}` : g.color === 'other' ? t('print.other') : '—'}</dd></div>
          <div className="fact"><dt>VIN</dt><dd className="mono">{g.vin || '—'}</dd></div>
          <div className="fact"><dt>{t('log.odometer')}</dt><dd>{toNum(g.odometer) === null ? '—' : fmtQty('distance', toNum(g.odometer), u)}</dd></div>
          <div className="fact"><dt>{t('print.mods')}</dt><dd>{g.mods.length ? g.mods.map((m) => m.title).join(', ') : t('print.none')}</dd></div>
        </dl>
      </section>
      <div className="print-cols">
        {SYSTEMS.map((sys) => (
          <section key={sys} className="print-sys">
            <h3>{t(`sys.${sys}` as MsgKey)}</h3>
            <table className="print-tbl"><tbody>
              {specs.filter((s) => s.system === sys).map((s) => {
                const c = s.value === null ? null : convertSpec(s.value, s.unit, u);
                return <tr key={s.id}><th>{s.label}</th><td>{c ? fmt(c.value, c.unit) : t('common.unknown')} <Badge c={s.confidence} /> <span className="print-src">{hostOf(s.source)}</span></td></tr>;
              })}
            </tbody></table>
          </section>
        ))}
      </div>
      <p className="small muted">{t('print.footer')}</p>
    </article>
  );
}
