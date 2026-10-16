import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { GO, createShortcuts } from '../lib/shortcuts';
import { useT } from './SettingsContext';
import type { MsgKey } from '../lib/i18n';

/** Global desktop shortcuts and the "?" help dialog. */
export function Shortcuts() {
  const nav = useNavigate();
  const t = useT();
  const [open, setOpen] = useState(false);
  const dlg = useRef<HTMLDialogElement>(null);
  const back = useRef<HTMLElement | null>(null);
  // One matcher and a ref to the latest navigate, so re-renders never drop a pending "g".
  const navRef = useRef(nav);
  navRef.current = nav;
  useEffect(() => {
    const match = createShortcuts();
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      const a = match(e);
      if (!a) return;
      if (a.kind === 'close') { setOpen(false); return; }
      e.preventDefault();
      if (a.kind === 'help') { back.current = document.activeElement as HTMLElement | null; setOpen((o) => !o); }
      else if (a.kind === 'go') { setOpen(false); navRef.current(a.to); }
      else if (a.kind === 'search') {
        setOpen(false);
        const box = document.getElementById('search-input') as HTMLInputElement | null;
        if (box) box.focus(); else navRef.current('/search', { state: { focus: true } });
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  useEffect(() => {
    const d = dlg.current;
    if (!d) return;
    if (open && !d.open) { if (typeof d.showModal === 'function') d.showModal(); else d.setAttribute('open', ''); }
    if (!open && d.open) { if (typeof d.close === 'function') d.close(); else d.removeAttribute('open'); back.current?.focus?.(); }
  }, [open]);
  const rows: [string, string][] = [
    ['/', t('keys.search')], ['?', t('keys.help')], ['Esc', t('keys.close')],
    ...Object.entries(GO).map(([k, v]): [string, string] => [`g ${k}`, t('keys.goto', { page: t(v.key as MsgKey) })]),
  ];
  return (
    <dialog ref={dlg} className="keys-dlg" aria-labelledby="keys-h" onClose={() => setOpen(false)} onClick={(e) => { if (e.target === dlg.current) setOpen(false); }}>
      <div className="keys-in">
      <h2 id="keys-h">{t('keys.title')}</h2>
      <p className="muted small">{t('keys.note')}</p>
      <table className="tbl keys-tbl">
        <thead><tr><th scope="col">{t('keys.key')}</th><th scope="col">{t('keys.action')}</th></tr></thead>
        <tbody>{rows.map(([k, d]) => <tr key={k}><td>{k.split(' ').map((x, i) => <span key={i}>{i ? ' ' : ''}<kbd>{x}</kbd></span>)}</td><td>{d}</td></tr>)}</tbody>
      </table>
      <div className="btn-row"><button className="btn" onClick={() => setOpen(false)} autoFocus>{t('keys.closeBtn')}</button></div>
      </div>
    </dialog>
  );
}
