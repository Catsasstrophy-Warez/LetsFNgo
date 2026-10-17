import { useState } from 'react';
import { Link } from 'react-router';
import { Cite } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { EXAMPLES, ask, type Answer } from '../lib/ask';

export default function Ask() {
  const t = useT();
  const [q, setQ] = useState('');
  const [res, setRes] = useState<{ q: string; a: Answer | null } | null>(null);
  const run = (text: string) => { const s = text.trim(); if (s) setRes({ q: s, a: ask(s) }); };
  return (
    <>
      <h1>{t('nav.ask')}</h1>
      <p className="lede">{t('ask.lede')}</p>
      <form className="card" role="search" onSubmit={(e) => { e.preventDefault(); run(q); }}>
        <label htmlFor="ask-q">{t('ask.label')}</label>
        <div className="photo-row">
          <input id="ask-q" className="input" value={q} maxLength={200} onChange={(e) => setQ(e.target.value)} placeholder={t('ask.ph')} autoComplete="off" />
          <button className="btn" type="submit">{t('ask.go')}</button>
        </div>
        <p className="muted small">{t('ask.try')}{' '}
          {EXAMPLES.map((x, i) => <span key={x}>{i > 0 && ' · '}<button type="button" className="link-btn" onClick={() => { setQ(x); run(x); }}>{x}</button></span>)}
        </p>
      </form>
      <section className="card" aria-live="polite" aria-labelledby="ask-res">
        <h2 id="ask-res">{t('ask.answer')}</h2>
        {!res ? <p className="muted">{t('ask.empty')}</p> : !res.a ? (
          <p><strong>{t('ask.notInData')}</strong> {t('ask.notInDataHint')} <Link to="/search">{t('nav.search')} →</Link></p>
        ) : (
          <>
            <p className="muted small">{t('ask.matched', { q: res.q, i: t(`ask.intent.${res.a.intent}` as never) })}</p>
            <ul className="rows">
              {res.a.facts.map((f, i) => (
                <li key={i}>
                  <div><strong>{f.label}</strong></div>
                  <div>{f.value}</div>
                  <div className="small"><Cite c={f.confidence} url={f.source} /> · <Link to={f.route}>{t('ask.open')}</Link></div>
                  {f.note && <div className="small muted">{f.note}</div>}
                </li>
              ))}
            </ul>
          </>
        )}
        <p className="note">{t('ask.note')}</p>
      </section>
    </>
  );
}
