import { useState } from 'react';
import { Link } from 'react-router';
import { Cite } from './Facts';
import { useT } from './SettingsContext';
import { MAX_ITEM_LEN, MAX_USER_ITEMS, factFor, loadPtc, savePtc, tirePressuresSourced, type CheckItem } from '../lib/preTrack';

/**
 * Interactive pre-track checklist for the session being logged. Sourced items show the badge and source of their
 * data record; the tire item asks for the owner's own target until a pressure is sourced. Owner items can be added
 * to (and removed from) the template kept on this device; the ticked list is saved with the session.
 */
/** Unique id for an owner item: two items added within the same millisecond used to share an id (and tick together). */
export function newUserItemId(items: { id: string }[], now = Date.now()): string {
  const base = `ptc-u${now.toString(36)}`;
  let id = base, k = 0;
  while (items.some((i) => i.id === id)) id = `${base}-${(++k).toString(36)}`;
  return id;
}

export function PreTrackChecklist({ items, onChange }: { items: CheckItem[]; onChange: (items: CheckItem[]) => void }) {
  const t = useT();
  const [text, setText] = useState('');
  const [err, setErr] = useState('');
  const userCount = items.filter((i) => i.id.startsWith('ptc-u')).length;
  const addItem = () => {
    const v = text.trim().slice(0, MAX_ITEM_LEN);
    if (!v) return;
    const tpl = loadPtc();
    if (tpl.items.length >= MAX_USER_ITEMS) { setErr(t('ptc.limit', { n: MAX_USER_ITEMS })); return; }
    savePtc({ items: [...tpl.items, v] });
    onChange([...items, { id: newUserItemId(items), label: v, done: false, kind: 'user' }]);
    setText(''); setErr('');
  };
  const removeItem = (it: CheckItem) => {
    const tpl = loadPtc();
    const k = tpl.items.indexOf(it.label);
    if (k >= 0) savePtc({ items: tpl.items.filter((_, i) => i !== k) });
    onChange(items.filter((x) => x.id !== it.id));
  };
  const done = items.filter((i) => i.done).length;
  return (
    <fieldset className="ptc">
      <legend>{t('ptc.title')} <span className="muted small">({t('ptc.progress', { d: done, n: items.length })})</span></legend>
      <p className="muted small">{t('ptc.lede')} <Link to="/guides/track-service">{t('garage.trackGuideLink')}</Link></p>
      {items.map((it) => {
        const f = it.factId ? factFor(it.factId) : undefined;
        return (
          <div key={it.id} className="row-main">
            <label className="check">
              <input type="checkbox" checked={it.done} onChange={(e) => onChange(items.map((x) => (x.id === it.id ? { ...x, done: e.target.checked } : x)))} />
              <span>{it.label}{f && <> <Cite c={f.confidence} url={f.source} /></>}{it.id === 'ptc-tires' && !tirePressuresSourced() && <span className="muted small"> {t('ptc.tiresNote')}</span>}</span>
            </label>
            {it.id.startsWith('ptc-u') && <button type="button" className="link-btn small" onClick={() => removeItem(it)} aria-label={t('common.removeX', { x: it.label })}>{t('common.remove')}</button>}
          </div>
        );
      })}
      {userCount < MAX_USER_ITEMS && (
        <div className="photo-row">
          <input className="input" value={text} maxLength={MAX_ITEM_LEN} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); addItem(); } }} aria-label={t('ptc.newItem')} placeholder={t('ptc.newItemPh')} />
          <button type="button" className="btn ghost" onClick={addItem}>{t('ptc.add')}</button>
        </div>
      )}
      {err && <p className="err small" role="alert">{err}</p>}
    </fieldset>
  );
}

/** Read-only view of a saved session's checklist. */
export function SavedChecklist({ items }: { items: CheckItem[] }) {
  const t = useT();
  if (!items.length) return null;
  return (
    <details className="sub">
      <summary>{t('ptc.saved', { d: items.filter((i) => i.done).length, n: items.length })}</summary>
      <ul className="rows small">
        {items.map((i) => <li key={i.id}><span aria-hidden="true">{i.done ? '☑' : '☐'}</span> <span className="sr-only">{i.done ? t('ptc.done') : t('ptc.notDone')}</span> {i.label}</li>)}
      </ul>
    </details>
  );
}
