import { OsmCredit } from '../components/SourcedLine';
import { Link } from 'react-router';
import { Badge } from '../components/Facts';
import { useT } from '../components/SettingsContext';
import type { MsgKey } from '../lib/i18n';

/** Each tool: route, nav label, and its one-line help text (help.tool.<id>). */
const TOOLS: [string, string][] = [
  ['/specs', 'specs'], ['/vin', 'vin'], ['/editions', 'editions'], ['/history', 'history'], ['/market', 'market'], ['/garage', 'garage'],
  ['/report', 'report'], ['/planner', 'planner'], ['/track', 'track'], ['/timer', 'timer'], ['/drag', 'drag'], ['/gps', 'gps'], ['/laptimer', 'laptimer'], ['/obd', 'obd'], ['/tree', 'tree'], ['/trackdays', 'trackdays'], ['/ask', 'ask'], ['/dyno', 'dyno'],
  ['/fuel', 'fuel'], ['/tires', 'tires'], ['/gearing', 'gearing'], ['/parts', 'parts'], ['/guides', 'guides'], ['/timeline', 'timeline'],
  ['/achievements', 'achievements'], ['/sources', 'sources'],
];

/** In-app user guide: what each tool does, what the confidence badges mean, privacy and backups. */
export default function Help() {
  const t = useT();
  return (
    <>
      <h1>{t('nav.help')}</h1>
      <p className="lede">{t('help.lede')}</p>
      <nav className="card" aria-labelledby="help-toc">
        <h2 id="help-toc">{t('help.toc')}</h2>
        <ul>
          <li><a href="#/help" onClick={(e) => { e.preventDefault(); document.getElementById('help-tools')?.scrollIntoView(); }}>{t('help.tools')}</a></li>
          <li><a href="#/help" onClick={(e) => { e.preventDefault(); document.getElementById('help-badges')?.scrollIntoView(); }}>{t('help.badges')}</a></li>
          <li><a href="#/help" onClick={(e) => { e.preventDefault(); document.getElementById('help-privacy')?.scrollIntoView(); }}>{t('help.privacy')}</a></li>
          <li><a href="#/help" onClick={(e) => { e.preventDefault(); document.getElementById('help-backup')?.scrollIntoView(); }}>{t('help.backup')}</a></li>
          <li><a href="#/help" onClick={(e) => { e.preventDefault(); document.getElementById('help-data')?.scrollIntoView(); }}>{t('osm.title')}</a></li>
        </ul>
      </nav>
      <section className="card" aria-labelledby="help-tools">
        <h2 id="help-tools">{t('help.tools')}</h2>
        <dl className="help-list">
          {TOOLS.map(([to, id]) => (
            <div key={id}><dt><Link to={to}>{t(`nav.${id}` as MsgKey)}</Link></dt><dd>{t(`help.tool.${id}` as MsgKey)}</dd></div>
          ))}
        </dl>
      </section>
      <section className="card" aria-labelledby="help-badges">
        <h2 id="help-badges">{t('help.badges')}</h2>
        <p>{t('help.badgesText')}</p>
        <ul className="rows">
          <li><Badge c="confirmed" /> {t('help.badge.confirmed')}</li>
          <li><Badge c="reported" /> {t('help.badge.reported')}</li>
          <li><Badge c="unverified" /> {t('help.badge.unverified')}</li>
        </ul>
        <p className="muted">{t('help.badgesNull')}</p>
      </section>
      <section className="card" aria-labelledby="help-privacy">
        <h2 id="help-privacy">{t('help.privacy')}</h2>
        <p>{t('help.privacyText')}</p>
        <ul><li>{t('help.privacy1')}</li><li>{t('help.privacy2')}</li><li>{t('help.privacy3')}</li></ul>
      </section>
      <section className="card" aria-labelledby="help-backup">
        <h2 id="help-backup">{t('help.backup')}</h2>
        <p>{t('help.backupText')}</p>
        <ol><li>{t('help.backup1')}</li><li>{t('help.backup2')}</li><li>{t('help.backup3')}</li></ol>
        <p><Link to="/settings">{t('nav.settings')} →</Link></p>
      </section>
      <section className="card" aria-labelledby="help-data">
        <h2 id="help-data">{t('osm.title')}</h2>
        <p>{t('osm.text')} <OsmCredit /></p>
      </section>
    </>
  );
}
