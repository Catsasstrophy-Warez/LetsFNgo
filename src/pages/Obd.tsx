import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { Cite } from '../components/Facts';
import { useT, useUnits } from '../components/SettingsContext';
import {
  EMPTY_READING, MAP_MAX_KPA, MAX_SAMPLES, OBD_SOURCE, OIL_TEMP_NOTE_SOURCE, ObdClient, boostKpa, demoTransport, dtcLookupUrl, samplesCsv, summarize,
  type Dtc, type ObdSample, type PidKey, type Reading,
} from '../lib/obd';
import { bleSupport, connectBle } from '../lib/obdBle';
import { fmtQty, toDisplay, unitLabel, type Units } from '../lib/units';
import { downloadText } from '../lib/download';
import { KEYS, activeCarId, forCar, loadTrack, today } from '../lib/garage';
import { DRAG_KEY, loadDrag } from '../lib/drag';
import { save } from '../lib/storage';
import type { MsgKey } from '../lib/i18n';

const POLL_KEYS: PidKey[] = ['rpm', 'speed', 'coolant', 'iat', 'map', 'baro', 'throttle', 'oil'];
const KMH_MPH = 1.609344;
const cToF = (c: number) => c * 9 / 5 + 32;
const KPA_PSI = 0.1450377;

type Phase = 'idle' | 'connecting' | 'live' | 'error';
type GaugeId = 'rpm' | 'speed' | 'coolant' | 'iat' | 'boost' | 'throttle' | 'oil';

/** Display value, unit, scale max for one gauge (base readings are metric: km/h, °C, kPa). */
function gaugeOf(id: GaugeId, r: Reading, u: Units): { v: number | null; text: string; max: number; min: number } {
  switch (id) {
    case 'rpm': return { v: r.rpm, text: r.rpm === null ? '—' : `${Math.round(r.rpm).toLocaleString('en-US')} rpm`, min: 0, max: 8000 };
    case 'speed': { const mph = r.speed === null ? null : r.speed / KMH_MPH; return { v: mph === null ? null : toDisplay('speed', mph, u), text: fmtQty('speed', mph, u, 0), min: 0, max: u === 'metric' ? 300 : 200 }; }
    case 'coolant': case 'iat': case 'oil': { const c = r[id]; const f = c === null ? null : cToF(c); return { v: f === null ? null : toDisplay('temp', f, u), text: fmtQty('temp', f, u, 0), min: u === 'metric' ? -20 : 0, max: u === 'metric' ? 150 : 300 }; }
    case 'throttle': return { v: r.throttle, text: r.throttle === null ? '—' : `${Math.round(r.throttle)} %`, min: 0, max: 100 };
    case 'boost': { const b = boostKpa(r); const v = b === null ? null : u === 'metric' ? b : b * KPA_PSI; return { v, text: v === null ? '—' : `${v.toFixed(u === 'metric' ? 0 : 1)} ${u === 'metric' ? 'kPa' : 'psi'}`, min: u === 'metric' ? -100 : -15, max: u === 'metric' ? 160 : 23 }; }
  }
}

/** 240° arc gauge. The SVG is decorative; the value is in text and a <meter>. Changes are instant with reduced motion. */
function Gauge({ id, r, u, label }: { id: GaugeId; r: Reading; u: Units; label: string }) {
  const g = gaugeOf(id, r, u);
  const frac = g.v === null ? 0 : Math.max(0, Math.min(1, (g.v - g.min) / (g.max - g.min)));
  const arc = (f: number) => {
    const a0 = (150 * Math.PI) / 180, a = a0 + f * (240 * Math.PI) / 180;
    const x = 50 + 40 * Math.cos(a), y = 50 + 40 * Math.sin(a);
    return `M${(50 + 40 * Math.cos(a0)).toFixed(2)} ${(50 + 40 * Math.sin(a0)).toFixed(2)}A40 40 0 ${f * 240 > 180 ? 1 : 0} 1 ${x.toFixed(2)} ${y.toFixed(2)}`;
  };
  return (
    <div className="gauge">
      <svg viewBox="0 0 100 86" aria-hidden="true" className="gauge-svg">
        <path d={arc(0.9999)} className="gauge-track" />
        {frac > 0 && <path d={arc(frac)} className="gauge-fill" />}
      </svg>
      <div className="gauge-v mono">{g.text}</div>
      <label className="gauge-l">{label}
        <meter className="sr-only" min={g.min} max={g.max} value={g.v ?? g.min}>{g.text}</meter>
      </label>
    </div>
  );
}

export default function Obd() {
  const t = useT();
  const u = useUnits();
  const support = bleSupport();
  const [phase, setPhase] = useState<Phase>('idle');
  const [err, setErr] = useState('');
  const [name, setName] = useState('');
  const [reading, setReading] = useState<Reading>(EMPTY_READING);
  const [supported, setSupported] = useState<Set<PidKey>>(new Set());
  const [demo, setDemo] = useState(false);
  const [recording, setRecording] = useState(false);
  const [samples, setSamples] = useState<ObdSample[]>([]);
  const [dtcs, setDtcs] = useState<{ stored: Dtc[] | null; pending: Dtc[] | null } | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [attachTo, setAttachTo] = useState('');
  const client = useRef<ObdClient | null>(null);
  const alive = useRef(false);
  /** Poll-loop generation: a loop stops as soon as a newer one starts (or polling pauses). */
  const gen = useRef(0);
  const recRef = useRef(false);
  const t0 = useRef(0);
  recRef.current = recording;

  const stop = async () => {
    alive.current = false;
    const c = client.current; client.current = null;
    await c?.close().catch(() => undefined);
    setPhase('idle'); setRecording(false);
  };
  useEffect(() => () => { alive.current = false; client.current?.close().catch(() => undefined); }, []);

  const loop = async (c: ObdClient) => {
    const g = ++gen.current;
    const keys = POLL_KEYS.filter((k) => c.isSupported(k));
    while (alive.current && client.current === c && gen.current === g) {
      try {
        const r = await c.read(keys);
        if (!alive.current || gen.current !== g) break;
        setReading(r);
        if (recRef.current) setSamples((s) => (s.length >= MAX_SAMPLES ? s : [...s, { t: performance.now() - t0.current, r }]));
        if (c.simulated) await new Promise((ok) => setTimeout(ok, 250));
      } catch { setErr(t('obd.lost')); await stop(); setPhase('error'); break; }
    }
  };

  const begin = async (useDemo: boolean) => {
    setErr(''); setMsg(null); setDtcs(null); setSamples([]); setReading(EMPTY_READING);
    setPhase('connecting'); setDemo(useDemo);
    try {
      const tr = useDemo ? demoTransport() : await connectBle(() => { if (alive.current) { setErr(t('obd.lost')); stop(); setPhase('error'); } });
      setName(useDemo ? t('obd.demoName') : (tr as { name?: string }).name ?? '');
      const c = new ObdClient(tr);
      await c.init();
      await c.readSupported();
      setSupported(new Set(POLL_KEYS.filter((k) => c.isSupported(k))));
      client.current = c; alive.current = true; t0.current = performance.now();
      setPhase('live');
      loop(c);
    } catch (e) {
      setPhase('error');
      const m = e instanceof Error ? e.message : '';
      setErr(e instanceof DOMException && e.name === 'NotFoundError' ? t('obd.cancelled') : m === 'profile' ? t('obd.noProfile') : t('obd.failed'));
    }
  };

  const readCodes = async () => {
    const c = client.current;
    if (!c) return;
    gen.current++; // pause polling while the codes are read
    try { setDtcs(await c.readDtcs()); } catch { setErr(t('obd.dtcFailed')); }
    if (client.current === c) loop(c);
  };

  const live = phase === 'live';
  const sum = summarize(samples);
  const carId = activeCarId();
  const trackList = forCar(loadTrack(), carId).slice(-20).reverse();
  const dragList = forCar(loadDrag(), carId).filter((s) => !s.gps).slice(-20).reverse();
  const summaryText = () => [
    `OBD log ${today()}: ${sum.n} samples over ${sum.seconds} s`,
    sum.rpm !== null ? `max ${Math.round(sum.rpm)} rpm` : '',
    sum.speed !== null ? `max ${Math.round(sum.speed / KMH_MPH)} mph` : '',
    sum.coolant !== null ? `max coolant ${Math.round(cToF(sum.coolant))} °F` : '',
    sum.iat !== null ? `max IAT ${Math.round(cToF(sum.iat))} °F` : '',
    sum.boost !== null ? `max boost ${(sum.boost * KPA_PSI).toFixed(1)} psi (MAP − baro; MAP reads ≤ ${MAP_MAX_KPA} kPa)` : '',
    sum.oil !== null ? `max oil ${Math.round(cToF(sum.oil))} °F` : '',
  ].filter(Boolean).join(', ') + '.';
  const attach = () => {
    if (demo) return setMsg({ ok: false, text: t('obd.noAttachDemo') });
    if (!samples.length || !attachTo) return;
    const [kind, id] = attachTo.split(':');
    let ok = false;
    if (kind === 'track') { const all = loadTrack(); ok = save(KEYS.track, all.map((s) => (s.id === id ? { ...s, notes: [s.notes, summaryText()].filter(Boolean).join('\n') } : s))); }
    else { const all = loadDrag(); ok = save(DRAG_KEY, all.map((s) => (s.id === id ? { ...s, notes: [s.notes, summaryText()].filter(Boolean).join('\n') } : s))); }
    setMsg({ ok, text: ok ? t('obd.attached') : t('common.saveFailed') });
  };

  const show = (k: PidKey) => supported.has(k);
  const GAUGES: [GaugeId, MsgKey, boolean][] = [
    ['rpm', 'obd.g.rpm', show('rpm')], ['speed', 'obd.g.speed', show('speed')], ['boost', 'obd.g.boost', show('map') && show('baro')],
    ['throttle', 'obd.g.throttle', show('throttle')], ['coolant', 'obd.g.coolant', show('coolant')], ['iat', 'obd.g.iat', show('iat')], ['oil', 'obd.g.oil', show('oil')],
  ];

  return (
    <>
      <h1>{t('nav.obd')}</h1>
      <p className="lede">{t('obd.lede')}</p>
      <div className="card warn" role="note"><strong>{t('obd.safetyStrong')}</strong> {t('obd.safety')}</div>

      <section className="card" aria-labelledby="obd-conn">
        <h2 id="obd-conn">{t('obd.adapter')}</h2>
        {support !== 'ok' && <p className="muted">{t(support === 'insecure' ? 'obd.insecure' : 'obd.unsupported')}</p>}
        <p className="muted small">{t('obd.readOnly')}</p>
        <div className="btn-row">
          {live || phase === 'connecting'
            ? <button className="btn" onClick={stop}>{t('obd.disconnect')}</button>
            : <>
                {support === 'ok' && <button className="btn" onClick={() => begin(false)}>{t('obd.connect')}</button>}
                <button className="btn ghost" onClick={() => begin(true)}>{t('obd.demo')}</button>
              </>}
        </div>
        <p role="status" className="small">{phase === 'connecting' ? t('obd.connecting') : live ? t('obd.connected', { n: name }) : ''}</p>
        {err && <p className="err" role="alert">{err}</p>}
      </section>

      {live && (
        <section className="card" aria-labelledby="obd-g">
          <h2 id="obd-g">{t('obd.gauges')} {demo && <span className="badge badge-unverified demo-badge">{t('obd.demoBadge')}</span>}</h2>
          {demo && <p className="warn-t">{t('obd.demoNote')}</p>}
          <div className="gauges">
            {GAUGES.filter(([, , on]) => on).map(([id, k]) => <Gauge key={id} id={id} r={reading} u={u} label={t(k)} />)}
          </div>
          {GAUGES.some(([, , on]) => !on) && <p className="muted small">{t('obd.unsupportedPids', { list: GAUGES.filter(([, , on]) => !on).map(([, k]) => t(k)).join(', ') })}</p>}
          <div className="btn-row">
            <button className={`btn${recording ? '' : ' ghost'}`} aria-pressed={recording} onClick={() => { if (!recording) { setSamples([]); t0.current = performance.now(); } setRecording(!recording); }}>{recording ? t('obd.stopRec') : t('obd.rec')}</button>
            <button className="btn ghost" onClick={readCodes}>{t('obd.readCodes')}</button>
          </div>
          <p className="small muted" aria-live="polite">{t('obd.samples', { n: samples.length })}</p>
        </section>
      )}

      {samples.length > 0 && !recording && (
        <section className="card" aria-labelledby="obd-log">
          <h2 id="obd-log">{t('obd.session')}</h2>
          <p>{t('obd.sumLine', { n: sum.n, s: sum.seconds, rpm: sum.rpm === null ? '—' : Math.round(sum.rpm), v: fmtQty('speed', sum.speed === null ? null : sum.speed / KMH_MPH, u, 0) })}</p>
          <button className="btn ghost" onClick={() => downloadText(samplesCsv(samples, demo), `gt500-obd-${today()}${demo ? '-demo' : ''}.csv`, 'text/csv')}>{t('obd.csv')}</button>
          <h3>{t('obd.attach')}</h3>
          {demo ? <p className="muted small">{t('obd.noAttachDemo')}</p> : (trackList.length + dragList.length === 0 ? <p className="muted small">{t('obd.noEntries')} <Link to="/track">{t('nav.track')}</Link> · <Link to="/drag">{t('nav.drag')}</Link></p> : (
            <div className="photo-row">
              <label className="sr-only" htmlFor="obd-attach">{t('obd.attach')}</label>
              <select id="obd-attach" className="input" value={attachTo} onChange={(e) => setAttachTo(e.target.value)}>
                <option value="">{t('obd.pickEntry')}</option>
                {trackList.map((s) => <option key={s.id} value={`track:${s.id}`}>{t('nav.track')}: {s.date} {s.track}</option>)}
                {dragList.map((s) => <option key={s.id} value={`drag:${s.id}`}>{t('nav.drag')}: {s.date} {s.track}</option>)}
              </select>
              <button className="btn ghost" onClick={attach} disabled={!attachTo}>{t('obd.attachBtn')}</button>
            </div>
          ))}
          <p className="muted small">{t('obd.attachNote')}</p>
          {msg && <p className={msg.ok ? 'ok-t' : 'err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
        </section>
      )}

      {dtcs && (
        <section className="card" aria-labelledby="obd-dtc">
          <h2 id="obd-dtc">{t('obd.dtcTitle')} {demo && <span className="badge badge-unverified">{t('obd.demoBadge')}</span>}</h2>
          {(['stored', 'pending'] as const).map((k) => (
            <div key={k}>
              <h3>{t(k === 'stored' ? 'obd.stored' : 'obd.pending')}</h3>
              {dtcs[k] === null ? <p className="err">{t('obd.dtcUnreadable')}</p> : dtcs[k]!.length === 0 ? <p className="muted">{t('obd.noCodes')}</p> : <DtcList list={dtcs[k]!} />}
            </div>
          ))}
          <p className="muted small">{t('obd.noClear')}</p>
        </section>
      )}

      <section className="card" aria-labelledby="obd-about">
        <h2 id="obd-about">{t('obd.about')}</h2>
        <ul className="small">
          <li>{t('obd.about1')} <Cite c="confirmed" url={OBD_SOURCE} /></li>
          <li>{t('obd.about2', { kpa: MAP_MAX_KPA })}</li>
          <li>{t('obd.about3')} <Cite c="unverified" url={OIL_TEMP_NOTE_SOURCE} /></li>
          <li>{t('obd.about4')}</li>
          <li>{t('obd.about5', { u: unitLabel('temp', u) })}</li>
        </ul>
      </section>
    </>
  );
}

export function DtcList({ list }: { list: Dtc[] }) {
  const t = useT();
  return (
    <ul className="rows">
      {list.map((d) => (
        <li key={d.code}>
          <strong className="mono">{d.code}</strong> <span className="muted small">{t(`obd.sys.${d.system}` as MsgKey)} · {t(d.generic ? 'obd.generic' : 'obd.mfr')}</span>
          <div className="small">{t('obd.noDesc')} <a href={dtcLookupUrl(d.code)} target="_blank" rel="noopener noreferrer">{t('obd.lookup', { c: d.code })} ↗</a></div>
        </li>
      ))}
    </ul>
  );
}
