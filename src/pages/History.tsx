import { useState } from 'react';
import { events as EV, historyGaps as GAPS, milestones as MS } from '../data/history';
import type { HistoryEvent, Milestone } from '../data/types';
import { Cite, Note } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import { historyTimeline } from '../lib/catalog';
import type { MsgKey } from '../lib/i18n';

type Show = 'all' | 'milestone' | 'event';
const SHOWS: Show[] = ['all', 'milestone', 'event'];

/** Events & history: press milestones and owner events on one vertical timeline, sourced per row. */
export default function History({ events = EV, milestones = MS, gaps = GAPS }: { events?: HistoryEvent[]; milestones?: Milestone[]; gaps?: string[] }) {
  const t = useT();
  const [show, setShow] = useState<Show>('all');
  const items = historyTimeline(events, milestones, show);
  const empty = events.length + milestones.length === 0;
  return (
    <>
      <h1>{t('nav.history')}</h1>
      <p className="lede">{t('hist.lede')}</p>
      {empty ? (
        <section className="card" aria-labelledby="hist-empty">
          <h2 id="hist-empty">{t('hist.emptyTitle')}</h2>
          <p className="muted">{t('hist.empty')}</p>
        </section>
      ) : (
        <section className="card" aria-labelledby="hist-h">
          <h2 id="hist-h">{t('hist.timeline')}</h2>
          <div className="seg" role="group" aria-label={t('hist.show')}>
            {SHOWS.map((s) => <button key={s} aria-pressed={show === s} className={show === s ? 'on' : ''} onClick={() => setShow(s)}>{t(`hist.show.${s}` as MsgKey)}</button>)}
          </div>
          <ol className="timeline hist">
            {items.map((x) => (
              <li key={x.id} className={`tl tl-${x.kind === 'milestone' ? 'ms' : 'ev'}`}>
                <div className="tl-date mono">{x.kind === 'event' && x.item.dateText ? x.item.dateText : x.date ?? t('hist.undated')}</div>
                <div className="tl-body">
                  <span className="tag">{x.kind === 'milestone' ? t('hist.milestone') : t(`hist.kind.${x.item.kind}` as MsgKey)}</span>{' '}
                  <strong>{x.kind === 'milestone' ? x.item.title : x.item.name}</strong>
                  {x.kind === 'event' && <div className="small muted">{[x.item.location ?? t('hist.locUnknown'), x.item.cost].filter(Boolean).join(' · ')}</div>}
                  {x.kind === 'milestone' && x.item.placement === null && <div className="small muted">{t('hist.placementUnknown')}</div>}
                  {x.item.note && <div className="small muted wrap">{x.item.note}</div>}
                  <div className="small"><Cite c={x.item.confidence} url={x.item.source} /></div>
                </div>
              </li>
            ))}
          </ol>
        </section>
      )}
      {gaps.length > 0 && (
        <section className="card">
          <h2>{t('ed.gaps')}</h2>
          <p className="muted">{t('hist.gapsText')}</p>
          <ul>{gaps.map((g) => <li key={g}>{g}</li>)}</ul>
        </section>
      )}
      <Note>{t('hist.note')}</Note>
    </>
  );
}
