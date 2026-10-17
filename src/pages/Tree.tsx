import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { useT } from '../components/SettingsContext';
import { classify, lightsAt, loadTree, randomDelay, saveTree, schedule, stats, TIMEOUT_MS, type Result, type Schedule, type TreeMode } from '../lib/tree';

type State = 'idle' | 'running' | 'done';
const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

export default function Tree() {
  const t = useT();
  const [mode, setMode] = useState<TreeMode>('sportsman');
  const [state, setState] = useState<State>('idle');
  const [sched, setSched] = useState<Schedule | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [result, setResult] = useState<Result | null>(null);
  const [timedOut, setTimedOut] = useState(false);
  const [history, setHistory] = useState<Result[]>(loadTree);
  const start = useRef(0);
  const raf = useRef<number | null>(null);

  const cancel = () => { if (raf.current !== null) cancelAnimationFrame(raf.current); raf.current = null; };
  useEffect(() => cancel, []);

  const stage = () => {
    cancel();
    const s = schedule(mode, randomDelay(Math.random()));
    setSched(s); setResult(null); setTimedOut(false); setElapsed(0); setState('running');
    start.current = now();
    const tick = () => {
      const e = now() - start.current;
      setElapsed(e);
      if (e > s.green + TIMEOUT_MS) { setState('done'); setTimedOut(true); raf.current = null; return; }
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
  };

  const tap = (stamp?: number) => {
    if (state !== 'running' || !sched) { stage(); return; }
    // Event timestamps share performance.now()'s clock, so the tap time is not delayed by rendering.
    const at = (stamp && stamp > start.current ? stamp : now()) - start.current;
    cancel();
    const r = classify(sched, at);
    setElapsed(at); setState('done');
    if (!r) { setTimedOut(true); return; }
    setResult(r);
    const next = [...history, r];
    setHistory(next); saveTree(next);
  };

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.code !== 'Space' || e.repeat) return;
      const tg = e.target as HTMLElement | null;
      if (tg && /^(INPUT|SELECT|TEXTAREA|BUTTON|A)$/.test(tg.tagName)) return;
      e.preventDefault(); tap(e.timeStamp);
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  });

  const L = sched ? lightsAt(sched, elapsed, !!result?.red) : { ambers: 0, green: false, red: false };
  const st = stats(history, mode);
  const fmt = (x: number | null) => (x === null ? '—' : x.toFixed(3));
  const statusText = state === 'running' ? (L.green ? t('tree.goNow') : t('tree.wait')) : result ? (result.red ? t('tree.redLight', { rt: fmt(result.rt) }) : t('tree.rt', { rt: fmt(result.rt) })) : timedOut ? t('tree.timeout') : t('tree.ready');

  return (
    <>
      <h1>{t('nav.tree')}</h1>
      <p className="lede">{t('tree.lede')} <Link to="/drag">{t('nav.drag')} →</Link></p>
      <section className="card" aria-labelledby="tree-h">
        <h2 id="tree-h" className="sr-only">{t('tree.title')}</h2>
        <fieldset className="seg" disabled={state === 'running'}>
          <legend>{t('tree.mode')}</legend>
          <label className="check"><input type="radio" name="tree-mode" checked={mode === 'sportsman'} onChange={() => setMode('sportsman')} /><span>{t('tree.sportsman')}</span></label>
          <label className="check"><input type="radio" name="tree-mode" checked={mode === 'pro'} onChange={() => setMode('pro')} /><span>{t('tree.pro')}</span></label>
        </fieldset>
        <div className="tree" aria-hidden="true">
          {[0, 1, 2].map((i) => <span key={i} className={`tree-lamp amber${(mode === 'pro' ? L.ambers > 0 : L.ambers > i) && !L.green ? ' on' : ''}`} />)}
          <span className={`tree-lamp green${L.green ? ' on' : ''}`} />
          <span className={`tree-lamp red${L.red ? ' on' : ''}`} />
        </div>
        <button className={`big-btn tree-btn ${state === 'running' ? 'go' : ''}`} onPointerDown={(e) => { e.preventDefault(); tap(e.timeStamp); }} onKeyDown={(e) => { if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) { e.preventDefault(); tap(e.timeStamp); } }}>
          {state === 'running' ? t('tree.tap') : t('tree.stage')}
        </button>
        <p className={`tree-status ${result?.red ? 'err' : ''}`} role="status" aria-live="assertive">{statusText}</p>
        <p className="muted small">{t('tree.keys')}</p>
      </section>
      <section className="card" aria-labelledby="tree-stats">
        <h2 id="tree-stats">{t('tree.stats', { m: t(mode === 'pro' ? 'tree.pro' : 'tree.sportsman') })}</h2>
        <div className="stats">
          <div className="stat"><div className="stat-v mono">{fmt(st.best)}</div><div className="stat-l">{t('tree.best')}</div></div>
          <div className="stat"><div className="stat-v mono">{fmt(st.avg)}</div><div className="stat-l">{t('tree.avg')}</div></div>
          <div className="stat"><div className="stat-v">{st.runs}</div><div className="stat-l">{t('tree.runs')}</div></div>
          <div className="stat"><div className="stat-v">{st.reds}</div><div className="stat-l">{t('tree.reds')}</div></div>
        </div>
        {history.length === 0 ? <p className="muted">{t('tree.none')}</p> : (
          <>
            <ol className="rows small" reversed>
              {history.slice(-10).reverse().map((r, i) => <li key={`${r.date}-${i}`}><span className="mono">{fmt(r.rt)} s</span> · {t(r.mode === 'pro' ? 'tree.pro' : 'tree.sportsman')}{r.red && <span className="tag">{t('tree.redTag')}</span>} <span className="muted">{r.date.slice(0, 10)}</span></li>)}
            </ol>
            <button className="btn ghost" onClick={() => { if (confirm(t('tree.confirmClear'))) { setHistory([]); saveTree([]); } }}>{t('tree.clear')}</button>
          </>
        )}
        <p className="note">{t('tree.note')}</p>
      </section>
    </>
  );
}
