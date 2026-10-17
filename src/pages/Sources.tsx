import { allSourceUrls, REPORT_PATH } from '../data';
import { hostOf } from '../components/Facts';
import { archivedUrl } from '../lib/coverage';
import { factRows, toCsv, toJson } from '../lib/factExport';
import { today } from '../lib/garage';
import { downloadText } from '../lib/download';
import { useT } from '../components/SettingsContext';
import { OsmCredit } from '../components/SourcedLine';


const download = (name: string, text: string, type: string) => downloadText(text, name, type);

function ExportFacts() {
  const t = useT();
  const n = factRows().length;
  return (
    <section className="card" id="export">
      <h2>{t('src.download')}</h2>
      <p className="muted">{t('src.downloadText', { n })}</p>
      <div className="btn-row">
        <button className="btn" onClick={() => download(`gt500-facts-${today()}.csv`, toCsv(factRows()), 'text/csv;charset=utf-8')}>{t('src.csv')}</button>
        <button className="btn ghost" onClick={() => download(`gt500-facts-${today()}.json`, toJson(factRows()), 'application/json')}>{t('src.json')}</button>
      </div>
    </section>
  );
}

export default function Sources() {
  const t = useT();
  const urls = allSourceUrls();
  const byHost = urls.reduce<Record<string, string[]>>((acc, u) => { (acc[hostOf(u)] ||= []).push(u); return acc; }, {});
  return (
    <>
      <h1>{t('nav.sources')}</h1>
      <p className="lede">{t('src.lede', { n: urls.length })} <code>{REPORT_PATH}</code></p>
      <section className="card" id="third-party">
        <h2>{t('osm.title')}</h2>
        <p>{t('osm.text')} <OsmCredit /></p>
      </section>
      <ExportFacts />
      {Object.keys(byHost).sort().map((h) => (
        <section key={h} className="card">
          <h2 className="host">{h}</h2>
          <ul className="srclist">{byHost[h].map((u) => <li key={u}><a href={u} target="_blank" rel="noopener noreferrer">{archivedUrl(u) ?? u}</a>{archivedUrl(u) && <span className="muted small"> — {t('src.archivedCopy')}</span>}</li>)}</ul>
        </section>
      ))}
    </>
  );
}
