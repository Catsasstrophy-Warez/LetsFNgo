import { Badge, Cite, Conflicts, Note } from '../components/Facts';
import { LineChart } from '../components/LineChart';
import { ScatterChart } from '../components/ScatterChart';
import { DynoChart } from '../components/DynoChart';
import { useT } from '../components/SettingsContext';
import type { DynoPull } from '../lib/dyno';

const SRC = 'https://example.com/source';
const LINE = [{ label: '2026-01', value: 11.4 }, { label: '2026-02', value: 11.1 }, { label: '2026-03', value: 11.25 }, { label: '2026-04', value: 10.98 }];
const SCATTER = [{ id: 'a', x: 1200, y: 92000, label: 'Car A' }, { id: 'b', x: 5400, y: 84000, label: 'Car B' }, { id: 'c', x: 15000, y: 76000, label: 'Car C' }];
const PULL = {
  id: 'g', date: '2026-01-01', shop: '', dynoType: 'dynojet', correction: 'sae', whp: 690, wtq: 590, notes: '', mods: [],
  weather: { tempF: null, pressureInHg: null, humidity: null, elevationFt: null, pressureIsStation: false },
  curve: [{ rpm: 3000, hp: 300, tq: 525 }, { rpm: 4500, hp: 480, tq: 560 }, { rpm: 6000, hp: 640, tq: 560 }, { rpm: 7000, hp: 690, tq: 518 }],
} as unknown as DynoPull;

function Panel({ theme }: { theme: 'dark' | 'light' }) {
  const t = useT();
  const p = theme;
  return (
    <section className="gallery-panel" data-theme={theme} aria-labelledby={`gal-${p}`}>
      <h2 id={`gal-${p}`}>{t(theme === 'dark' ? 'gal.dark' : 'gal.light')}</h2>
      <div className="card">
        <h3>{t('gal.badges')}</h3>
        <p><Badge c="confirmed" /> <Badge c="reported" /> <Badge c="unverified" /></p>
        <p><Cite c="confirmed" url={SRC} /></p>
        <Conflicts values={[{ value: 4171, source: SRC, confidence: 'confirmed', context: 'Ford' }, { value: 4225, source: SRC, confidence: 'reported', context: 'Magazine' }]} unit="lb" />
        <Note>{t('gal.note')}</Note>
      </div>
      <div className="card">
        <h3>{t('gal.cards')}</h3>
        <div className="stats">
          <div className="stat"><div className="stat-l">{t('cov.records')}</div><div className="stat-v">350</div></div>
          <div className="stat"><div className="stat-l">{t('cov.gaps')}</div><div className="stat-v">42</div></div>
        </div>
      </div>
      <div className="card">
        <h3>{t('gal.inputs')}</h3>
        <label>{t('gal.sample')}<input className="input" defaultValue="GT500" /></label>
        <label>{t('gal.select')}<select className="input" defaultValue="2020"><option>2020</option><option>2021</option><option>2022</option></select></label>
        <label className="check"><input type="checkbox" defaultChecked /><span>{t('gal.check')}</span></label>
        <div className="btn-row"><button className="btn">{t('gal.primary')}</button><button className="btn ghost">{t('gal.ghost')}</button></div>
      </div>
      <div className="card">
        <h3>{t('gal.charts')}</h3>
        <LineChart title={t('gal.series')} points={LINE} format={(v) => v.toFixed(2)} unit="s" lowerIsBetter refLine={{ value: 11, label: '11.00' }} />
        <ScatterChart title={t('gal.series')} points={SCATTER} fmtX={(v) => `${Math.round(v)} mi`} fmtY={(v) => `$${Math.round(v).toLocaleString('en-US')}`} xLabel="mi" yLabel="USD"
          marker={{ x: 5000, label: '5,000 mi' }} refY={{ y: 84000, label: 'median' }} tableLabel={t('chart.table')} empty="—" />
        <DynoChart pulls={[PULL]} label={() => 'Sample pull'} />
      </div>
    </section>
  );
}

/** Dev-only gallery (route /dev/gallery exists only when import.meta.env.DEV). */
export default function Gallery() {
  const t = useT();
  return (
    <>
      <h1>{t('gal.title')}</h1>
      <p className="lede">{t('gal.lede')}</p>
      <div className="gallery">
        <Panel theme="dark" />
        <Panel theme="light" />
      </div>
    </>
  );
}
