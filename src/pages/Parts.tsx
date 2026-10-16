import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { FITMENT_INFERRED, fpCatalog, partSlots } from '../data/parts';
import type { FpCatalogItem, ModelYear } from '../data/types';
import { DEFAULT_FP_FILTER, filterFp, type FpFilter } from '../lib/catalog';
import { usdWhole } from '../lib/format';
import type { MsgKey } from '../lib/i18n';
import { maintenance } from '../data/maintenance';
import { copyText, filterParts } from '../lib/parts';
import { useT } from '../components/SettingsContext';

export default function Parts({ fp = fpCatalog }: { fp?: FpCatalogItem[] }) {
  const t = useT();
  const [params, setParams] = useSearchParams();
  const q = params.get('q') ?? '';
  const [copied, setCopied] = useState<{ id: string; ok: boolean } | null>(null);
  const list = filterParts(q);
  const copy = async (id: string, number: string) => setCopied({ id, ok: await copyText(number) });
  const tab = params.get('tab') === 'fp' ? 'fp' : 'fluids';
  const setTab = (x: 'fp' | 'fluids') => setParams(x === 'fp' ? { tab: 'fp' } : {}, { replace: true });
  const tabBtn = (x: 'fp' | 'fluids', label: string) => (
    <button role="tab" id={`tab-${x}`} aria-controls={`panel-${x}`} aria-selected={tab === x} tabIndex={tab === x ? 0 : -1} className={tab === x ? 'on' : ''}
      onClick={() => setTab(x)} onKeyDown={(e) => { if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { const n = x === 'fp' ? 'fluids' : 'fp'; setTab(n); document.getElementById(`tab-${n}`)?.focus(); } }}>{label}</button>
  );
  return (
    <>
      <h1>{t('nav.parts')}</h1>
      <div className="seg" role="tablist" aria-label={t('parts.tabs')}>{tabBtn('fluids', t('parts.tab.fluids'))}{tabBtn('fp', t('parts.tab.fp'))}</div>
      {tab === 'fp' ? <div role="tabpanel" id="panel-fp" aria-labelledby="tab-fp"><FordPerformance items={fp} copy={copy} copied={copied} /></div> : (
      <div role="tabpanel" id="panel-fluids" aria-labelledby="tab-fluids">
      <p className="lede">{t('parts.lede')} <Link to="/garage#maintenance">{t('parts.reminders')}</Link></p>
      <div className="form">
        <label>{t('parts.search')}<input className="input" type="search" value={q} placeholder={t('parts.ph')} onChange={(e) => setParams(e.target.value ? { q: e.target.value } : {}, { replace: true })} /></label>
      </div>
      <p className="muted small" role="status">{t('parts.count', { n: list.length })}</p>
      <ul className="rows parts-list">
        {list.map((p) => {
          const facts = maintenance.filter((m) => p.maintenanceIds.includes(m.id));
          return (
            <li key={p.id} id={p.id} className={p.kind === 'avoid' ? 'avoid' : ''}>
              <div className="row-main">
                <span><strong className="mono part-no">{p.number}</strong> <span className="muted">{p.brand} · {p.category}</span></span>
                <button className="btn ghost small-btn" onClick={() => copy(p.id, p.number)} aria-label={t('parts.copyLabel', { n: p.number })}>{copied?.id === p.id ? (copied.ok ? t('parts.copied') : t('parts.copyFailed')) : t('parts.copy')}</button>
              </div>
              <p>{p.kind === 'avoid' && <strong className="err">{t('parts.avoid')}</strong>}{p.description}</p>
              <p className="small"><Cite c={p.confidence} url={p.source} />{p.note && <span className="muted"> {p.note}</span>}</p>
              {facts.length > 0 && <p className="small muted">{t('parts.related')} {facts.map((f, i) => <span key={f.id}>{i ? ', ' : ''}<Link to="/ownership">{f.item}</Link></span>)}</p>}
            </li>
          );
        })}
      </ul>
      {list.length === 0 && <p className="muted">{t('parts.noMatch', { q })}</p>}
      <section className="card">
        <h2>{t('parts.notSourced')}</h2>
        <p className="muted">{t('parts.notSourcedText')}</p>
        <ul>{partSlots.map((s) => <li key={s}>{s}</li>)}</ul>
      </section>
      <Note>{t('parts.note')}</Note>
      </div>
      )}
    </>
  );
}

const CATS: FpCatalogItem['category'][] = ['Body & aero', 'Engine', 'Fuel & cooling', 'Driveline', 'Appearance'];

/** Ford Performance catalog tab: M-numbers with current MSRP, emissions status and fitment years. */
function FordPerformance({ items, copy, copied }: { items: FpCatalogItem[]; copy: (id: string, n: string) => void; copied: { id: string; ok: boolean } | null }) {
  const t = useT();
  const [f, setF] = useState<FpFilter>(DEFAULT_FP_FILTER);
  if (items.length === 0) return (
    <section className="card" aria-labelledby="fp-empty">
      <h2 id="fp-empty">{t('fp.emptyTitle')}</h2>
      <p className="muted">{t('fp.empty')}</p>
    </section>
  );
  const list = filterFp(items, f);
  const asOf = items.find((p) => p.priceAsOf)?.priceAsOf ?? '';
  return (
    <>
      <p className="lede">{t('fp.lede', { d: asOf })}</p>
      <div className="form four">
        <label>{t('parts.search')}<input className="input" type="search" value={f.q} placeholder="M-6766" onChange={(e) => setF({ ...f, q: e.target.value })} /></label>
        <label>{t('fp.fits')}
          <select className="input" value={f.year ?? ''} onChange={(e) => setF({ ...f, year: e.target.value ? (Number(e.target.value) as ModelYear) : null })}>
            <option value="">{t('market.allYears')}</option><option value="2020">2020</option><option value="2021">2021</option><option value="2022">2022</option>
          </select>
        </label>
        <label>{t('fp.category')}
          <select className="input" value={f.category ?? ''} onChange={(e) => setF({ ...f, category: (e.target.value || null) as FpFilter['category'] })}>
            <option value="">{t('market.any')}</option>{CATS.map((c) => <option key={c} value={c}>{t(`fp.cat.${c}` as MsgKey)}</option>)}
          </select>
        </label>
      </div>
      <label className="check"><input type="checkbox" checked={f.explicitOnly} onChange={(e) => setF({ ...f, explicitOnly: e.target.checked })} /><span>{t('fp.explicitOnly')}</span></label>
      <p className="muted small" role="status">{t('fp.count', { n: list.length, all: items.length })}</p>
      <ul className="rows parts-list">
        {list.map((p) => (
          <li key={p.id} id={p.id}>
            <div className="row-main">
              <span><strong className="mono part-no">{p.number}</strong> <span className="muted">{t(`fp.cat.${p.category}` as MsgKey)}</span></span>
              <button className="btn ghost small-btn" onClick={() => copy(p.id, p.number)} aria-label={t('parts.copyLabel', { n: p.number })}>{copied?.id === p.id ? (copied.ok ? t('parts.copied') : t('parts.copyFailed')) : t('parts.copy')}</button>
            </div>
            <p>{p.name}</p>
            <p className="small">
              <strong>{p.msrp !== null ? usdWhole(p.msrp) : t('common.unknown')}</strong> <span className="muted">{t('fp.msrp', { d: p.priceAsOf ?? '—' })}</span>
              {' · '}{t('fp.emissions')}: {p.emissions ?? t('fp.emissionsUnknown')}
              {' · '}{t('fp.fitment')}: {p.fitmentYears.join(', ') || t('common.unknown')} {p.fitmentExplicit ? <span className="tag">{t('fp.explicit')}</span> : <span className="badge badge-unverified">{t('fp.inferred')}</span>}
            </p>
            {!p.fitmentExplicit && <p className="small fit-note">{t('fp.inferredNote')}</p>}
            <p className="small"><Cite c={p.confidence} url={p.source} /> <span className="muted">{t('ed.research', { l: p.research })}</span>{p.note && p.note !== FITMENT_INFERRED && <span className="muted"> {p.note}</span>}</p>
          </li>
        ))}
      </ul>
      {list.length === 0 && <p className="muted">{t('fp.noMatch')}</p>}
      <Note>{t('fp.note')}</Note>
    </>
  );
}
