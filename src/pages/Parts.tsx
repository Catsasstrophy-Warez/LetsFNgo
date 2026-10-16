import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { Cite, Note } from '../components/Facts';
import { partSlots } from '../data/parts';
import { maintenance } from '../data/maintenance';
import { copyText, filterParts } from '../lib/parts';
import { useT } from '../components/SettingsContext';

export default function Parts() {
  const t = useT();
  const [params, setParams] = useSearchParams();
  const q = params.get('q') ?? '';
  const [copied, setCopied] = useState<{ id: string; ok: boolean } | null>(null);
  const list = filterParts(q);
  const copy = async (id: string, number: string) => setCopied({ id, ok: await copyText(number) });
  return (
    <>
      <h1>{t('nav.parts')}</h1>
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
    </>
  );
}
