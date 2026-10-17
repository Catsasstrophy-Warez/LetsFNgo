import { useState } from 'react';
import { Link } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import type { ModelYear } from '../data/types';
import type { MsgKey } from '../lib/i18n';
import { usdWhole } from '../lib/format';
import { BUILD_YEARS, buildSticker, loadBuild, optionsFor, saveBuild, type BuildState, type StickerLine } from '../lib/buildSheet';

/** Build & sticker: pick a model year and options, see the original MSRP as a sourced window sticker. */
export default function BuildSheet() {
  const t = useT();
  const [b, setB] = useState<BuildState>(loadBuild);
  const [saveErr, setSaveErr] = useState(false);
  const commit = (next: BuildState) => { setB(next); setSaveErr(!saveBuild(next)); };
  const offered = optionsFor(b.year);
  const st = buildSticker(b.year, b.options);

  const label = (l: StickerLine) => (l.kind === 'option' ? l.label : t(`build.kind.${l.kind}` as MsgKey));
  const price = (l: StickerLine) => (l.value === null ? <span className="muted">{t('build.unpriced')}</span> : <strong>{usdWhole(l.value)}</strong>);

  return (
    <>
      <h1>{t('nav.build')}</h1>
      <p className="lede">{t('build.lede')}</p>
      <Note>{t('build.disclaimer')}</Note>

      <section className="card no-print" aria-labelledby="build-pick">
        <h2 id="build-pick">{t('build.pickTitle')}</h2>
        <label>{t('build.year')}
          <select className="input" value={b.year} onChange={(e) => commit({ ...b, year: Number(e.target.value) as ModelYear })}>
            {BUILD_YEARS.map((y) => <option key={y} value={y}>{y}</option>)}
          </select>
        </label>
        <fieldset>
          <legend>{t('build.options', { y: b.year })}</legend>
          <ul className="rows">
            {offered.map(({ pkg, availability }) => (
              <li key={pkg.id}>
                <label>
                  <input type="checkbox" checked={b.options.includes(pkg.id)}
                    onChange={(e) => commit({ ...b, options: e.target.checked ? [...b.options, pkg.id] : b.options.filter((x) => x !== pkg.id) })} />{' '}
                  {pkg.name}
                </label>
                {availability === 'unverified' && <span className="small muted"> · {t('build.availUnverified')}</span>}
              </li>
            ))}
          </ul>
        </fieldset>
        {saveErr && <p className="err" role="alert">{t('build.saveErr')}</p>}
      </section>

      <section className="card" aria-labelledby="build-sticker">
        <h2 id="build-sticker">{t('build.stickerTitle', { y: b.year })}</h2>
        <table className="print-tbl">
          <caption className="small muted">{t('build.caption')}</caption>
          <thead><tr><th scope="col">{t('build.colItem')}</th><th scope="col">{t('build.colPrice')}</th></tr></thead>
          <tbody>
            {st.lines.map((l) => (
              <tr key={l.id}>
                <th scope="row">{label(l)}{l.context ? <span className="small muted"> ({l.context})</span> : null}
                  {l.kind === 'option' && offered.find((o) => o.pkg.id === l.id)?.availability === 'unverified' && <div className="small muted">{t('build.availUnverified')}</div>}
                </th>
                <td>{price(l)} {l.source ? <Cite c={l.confidence} url={l.source} /> : <span className="small muted">{t('build.noRecord')}</span>}
                  {l.conflicts.length > 0 && (
                    <div className="small">{t('build.conflicts')}{' '}
                      {l.conflicts.map((c, i) => (
                        <span key={i}>{i > 0 ? '; ' : ''}{c.value === null ? t('build.unpriced') : usdWhole(c.value)}{c.context ? ` (${c.context})` : ''} <Cite c={c.confidence} url={c.source} /></span>
                      ))}
                    </div>
                  )}
                  {l.note && <div className="print-src">{l.note}</div>}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><th scope="row">{t('build.total')}</th>
              <td role="status"><strong>{st.atLeast ? t('build.atLeast', { a: usdWhole(st.total) }) : usdWhole(st.total)}</strong>
                {st.unpriced > 0 && <div className="small muted">{t('build.unpricedCount', { n: st.unpriced })}</div>}</td></tr>
          </tfoot>
        </table>
        <div className="btn-row no-print">
          <button className="btn ghost" onClick={() => window.print()}>{t('build.print')}</button>
          <button className="btn ghost" onClick={() => commit({ ...b, options: [] })}>{t('build.clear')}</button>
        </div>
      </section>

      <section className="card no-print" aria-labelledby="build-today">
        <h2 id="build-today">{t('build.todayTitle')}</h2>
        <p>{t('build.todayText', { a: usdWhole(st.total), y: b.year })}</p>
        <p><Link to="/market">{t('nav.market')}</Link> · <Link to="/buy">{t('build.todayBuy')}</Link></p>
      </section>
    </>
  );
}
