import { useState } from 'react';
import { Link } from 'react-router';
import { useT } from '../components/SettingsContext';
import { tracks } from '../data/tracks';
import { TrackNoise } from '../components/TrackNoise';
import { today, uid } from '../lib/garage';
import { downloadText } from '../lib/download';
import type { MsgKey } from '../lib/i18n';
import {
  MAX_EVENTS, PACK_TEMPLATES, daysUntil, loadTrackDays, packFrom, saveTrackDays, splitDays, trackDaysToIcs, type PackTemplate, type TrackDay,
} from '../lib/trackdays';

const EMPTY = { date: '', endDate: '', trackId: '', custom: '', group: '', org: '', notes: '', template: 'hpde' as PackTemplate | '' };

export default function TrackDays() {
  const t = useT();
  const [list, setList] = useState<TrackDay[]>(loadTrackDays);
  const [f, setF] = useState(EMPTY);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const td = today();
  const { upcoming, past } = splitDays(list, td);
  const commit = (next: TrackDay[]) => { setList(next); if (!saveTrackDays(next)) setMsg({ ok: false, text: t('common.saveFailed') }); };

  const add = () => {
    const tr = tracks.find((x) => x.id === f.trackId);
    const name = tr ? tr.name : f.custom.trim();
    if (!f.date) return setMsg({ ok: false, text: t('td.errDate') });
    if (!name) return setMsg({ ok: false, text: t('td.errTrack') });
    if (f.endDate && f.endDate < f.date) return setMsg({ ok: false, text: t('td.errEnd') });
    if (list.length >= MAX_EVENTS) return setMsg({ ok: false, text: t('td.limit', { n: MAX_EVENTS }) });
    const ev: TrackDay = { id: uid(), date: f.date, endDate: f.endDate, trackId: tr?.id ?? '', track: name, group: f.group.trim(), org: f.org.trim(), notes: f.notes.trim(),
      pack: f.template ? packFrom(PACK_TEMPLATES[f.template].map((k) => t(`pack.${k}` as MsgKey))) : [] };
    commit([...list, ev]); setF(EMPTY); setMsg({ ok: true, text: t('td.added', { t: name, d: f.date }) });
  };
  const update = (id: string, fn: (d: TrackDay) => TrackDay) => commit(list.map((d) => (d.id === id ? fn(d) : d)));
  const exportIcs = () => {
    if (!upcoming.length) return setMsg({ ok: false, text: t('td.noUpcoming') });
    downloadText(trackDaysToIcs(upcoming), 'gt500-track-days.ics', 'text/calendar');
    setMsg({ ok: true, text: t('td.icsDone', { n: upcoming.length }) });
  };

  const Row = ({ d }: { d: TrackDay }) => {
    const n = daysUntil(d.date, td);
    const done = d.pack.filter((p) => p.done).length;
    return (
      <li className="card">
        <div className="row-main">
          <h3>{d.track}</h3>
          <button className="link-btn danger" onClick={() => { if (confirm(t('td.confirmDelete'))) commit(list.filter((x) => x.id !== d.id)); }} aria-label={t('common.deleteX', { x: `${d.track} ${d.date}` })}>{t('common.delete')}</button>
        </div>
        <p className="muted small">{d.date}{d.endDate && d.endDate !== d.date ? ` – ${d.endDate}` : ''} · {n > 0 ? t('td.inDays', { n }) : n === 0 || (d.endDate && d.endDate >= td) ? t('td.today') : t('td.past')}
          {d.org && <> · {d.org}</>}{d.group && <> · {t('td.group')}: {d.group}</>}</p>
        {(() => { const tr = tracks.find((x) => x.id === d.trackId); return tr ? <TrackNoise track={tr} /> : null; })()}
        {d.notes && <p className="small">{d.notes}</p>}
        {d.pack.length > 0 && (
          <details open={open === d.id} onToggle={(e) => setOpen((e.target as HTMLDetailsElement).open ? d.id : null)}>
            <summary>{t('td.packing', { d: done, n: d.pack.length })}</summary>
            <ul className="rows small">
              {d.pack.map((p) => (
                <li key={p.id}><label className="check"><input type="checkbox" checked={p.done} onChange={(e) => update(d.id, (x) => ({ ...x, pack: x.pack.map((q) => (q.id === p.id ? { ...q, done: e.target.checked } : q)) }))} /><span>{p.label}</span></label></li>
              ))}
            </ul>
          </details>
        )}
        <p className="small"><Link to="/track">{t('td.preTrack')}</Link> · <Link to="/laptimer">{t('nav.laptimer')}</Link></p>
      </li>
    );
  };

  return (
    <>
      <h1>{t('nav.trackdays')}</h1>
      <p className="lede">{t('td.lede')}</p>
      <section className="card" aria-labelledby="td-add">
        <h2 id="td-add">{t('td.add')}</h2>
        <div className="grid2">
          <label>{t('td.date')}<input className="input" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></label>
          <label>{t('td.endDate')}<input className="input" type="date" value={f.endDate} min={f.date || undefined} onChange={(e) => setF({ ...f, endDate: e.target.value })} /></label>
        </div>
        <label>{t('td.track')}
          <select className="input" value={f.trackId} onChange={(e) => setF({ ...f, trackId: e.target.value })}>
            <option value="">{t('td.otherTrack')}</option>
            {tracks.map((x) => <option key={x.id} value={x.id}>{x.name} ({x.state})</option>)}
          </select>
        </label>
        {(() => { const sel = tracks.find((x) => x.id === f.trackId); return sel ? <TrackNoise track={sel} /> : null; })()}
        {!f.trackId && <label>{t('td.customTrack')}<input className="input" value={f.custom} maxLength={200} onChange={(e) => setF({ ...f, custom: e.target.value })} /></label>}
        <div className="grid2">
          <label>{t('td.org')}<input className="input" value={f.org} maxLength={200} onChange={(e) => setF({ ...f, org: e.target.value })} placeholder={t('td.orgPh')} /></label>
          <label>{t('td.group')}<input className="input" value={f.group} maxLength={60} onChange={(e) => setF({ ...f, group: e.target.value })} placeholder={t('td.groupPh')} /></label>
        </div>
        <label>{t('td.template')}
          <select className="input" value={f.template} onChange={(e) => setF({ ...f, template: e.target.value as PackTemplate | '' })}>
            <option value="hpde">{t('td.tpl.hpde')}</option><option value="drag">{t('td.tpl.drag')}</option><option value="autox">{t('td.tpl.autox')}</option><option value="">{t('td.tpl.none')}</option>
          </select>
        </label>
        <label>{t('td.notes')}<textarea className="input" value={f.notes} maxLength={1000} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
        <div className="btn-row"><button className="btn" onClick={add}>{t('td.addBtn')}</button><button className="btn ghost" onClick={exportIcs}>{t('td.ics')}</button></div>
        {msg && <p className={msg.ok ? 'ok-t' : 'err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
        <p className="muted small">{t('td.note')}</p>
      </section>
      <section aria-labelledby="td-up">
        <h2 id="td-up">{t('td.upcoming')}</h2>
        {upcoming.length === 0 ? <p className="muted">{t('td.none')}</p> : <ul className="plain">{upcoming.map((d) => <Row key={d.id} d={d} />)}</ul>}
      </section>
      {past.length > 0 && (
        <section aria-labelledby="td-past">
          <h2 id="td-past">{t('td.pastH')}</h2>
          <ul className="plain">{past.map((d) => <Row key={d.id} d={d} />)}</ul>
        </section>
      )}
    </>
  );
}
