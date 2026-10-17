import { Suspense, lazy, useEffect, useState } from 'react';
import { NavLink, Route, Routes, useLocation, useNavigate } from 'react-router';
import { needsOnboarding } from './lib/onboarding';
import { checkReminders } from './lib/notify';
import { loadSettings, resolveTheme, saveSettings, type Settings } from './lib/units';
import { SettingsContext } from './components/SettingsContext';
import { ErrorBoundary } from './components/ErrorBoundary';
import { StatusBar } from './components/StatusBar';
import Home from './pages/Home';
import { isLangLoaded, loadLang, setCurrentLang, translate, type MsgKey } from './lib/i18n';
import { usePrefetch } from './lib/prefetch';
import { CarContext, useCarState } from './components/CarContext';
import { Shortcuts } from './components/Shortcuts';
import { InstallPrompt } from './components/InstallPrompt';

// Every route except Home is code-split; main.tsx warms these chunks so the PWA works offline.
export const PAGES = {
  Specs: () => import('./pages/Specs'),
  ModelYears: () => import('./pages/ModelYears'),
  Colors: () => import('./pages/Colors'),
  Packages: () => import('./pages/Packages'),
  Performance: () => import('./pages/Performance'),
  Vin: () => import('./pages/Vin'),
  Ownership: () => import('./pages/Ownership'),
  Garage: () => import('./pages/Garage'),
  Mods: () => import('./pages/Mods'),
  Compare: () => import('./pages/Compare'),
  Media: () => import('./pages/Media'),
  Community: () => import('./pages/Community'),
  Sources: () => import('./pages/Sources'),
  Search: () => import('./pages/Search'),
  Gearing: () => import('./pages/Gearing'),
  PerfTools: () => import('./pages/PerfTools'),
  Planner: () => import('./pages/Planner'),
  Track: () => import('./pages/Track'),
  Settings: () => import('./pages/Settings'),
  Drag: () => import('./pages/Drag'),
  Fuel: () => import('./pages/Fuel'),
  Visualizer: () => import('./pages/Visualizer'),
  PrintSheet: () => import('./pages/PrintSheet'),
  Quiz: () => import('./pages/Quiz'),
  Timer: () => import('./pages/Timer'),
  GpsMeter: () => import('./pages/GpsMeter'),
  Timeline: () => import('./pages/Timeline'),
  YearCompare: () => import('./pages/YearCompare'),
  Welcome: () => import('./pages/Welcome'),
  Dyno: () => import('./pages/Dyno'),
  Tires: () => import('./pages/Tires'),
  Share: () => import('./pages/Share'),
  Parts: () => import('./pages/Parts'),
  Guides: () => import('./pages/Guides'),
  Guide: () => import('./pages/Guide'),
  Report: () => import('./pages/Report'),
  Market: () => import('./pages/Market'),
  Achievements: () => import('./pages/Achievements'),
  Editions: () => import('./pages/Editions'),
  History: () => import('./pages/History'),
  Help: () => import('./pages/Help'),
  Coverage: () => import('./pages/Coverage'),
  LapTimer: () => import('./pages/LapTimer'),
};
/** Dev-only component gallery: `import.meta.env.DEV` is false in production, so the chunk is never built. */
const Gallery = import.meta.env.DEV ? lazy(() => import('./pages/Gallery')) : null;
/** First path segment → chunk, for hover/visible-link prefetch. */
const ROUTE_LOADERS: Record<string, () => Promise<unknown>> = {
  '/specs': PAGES.Specs, '/years': PAGES.ModelYears, '/colors': PAGES.Colors, '/packages': PAGES.Packages, '/performance': PAGES.Performance,
  '/vin': PAGES.Vin, '/ownership': PAGES.Ownership, '/garage': PAGES.Garage, '/mods': PAGES.Mods, '/compare': PAGES.Compare, '/media': PAGES.Media,
  '/community': PAGES.Community, '/sources': PAGES.Sources, '/search': PAGES.Search, '/gearing': PAGES.Gearing, '/tools': PAGES.PerfTools,
  '/planner': PAGES.Planner, '/track': PAGES.Track, '/settings': PAGES.Settings, '/drag': PAGES.Drag, '/fuel': PAGES.Fuel, '/visualizer': PAGES.Visualizer,
  '/print': PAGES.PrintSheet, '/quiz': PAGES.Quiz, '/timer': PAGES.Timer, '/gps': PAGES.GpsMeter, '/laptimer': PAGES.LapTimer, '/timeline': PAGES.Timeline, '/diff': PAGES.YearCompare,
  '/welcome': PAGES.Welcome, '/dyno': PAGES.Dyno, '/tires': PAGES.Tires, '/share': PAGES.Share, '/parts': PAGES.Parts,
  '/report': PAGES.Report, '/market': PAGES.Market, '/achievements': PAGES.Achievements,
  '/editions': PAGES.Editions, '/history': PAGES.History, '/help': PAGES.Help, '/coverage': PAGES.Coverage,
  '/guides': () => Promise.all([PAGES.Guides(), PAGES.Guide()]),
};
const L = Object.fromEntries(Object.entries(PAGES).map(([k, f]) => [k, lazy(f as () => Promise<{ default: () => JSX.Element }>)])) as Record<keyof typeof PAGES, React.LazyExoticComponent<() => JSX.Element>>;

export const NAV = [
  { to: '/', label: 'Home', key: 'nav.home' as MsgKey },
  { to: '/specs', label: 'Specs', key: 'nav.specs' as MsgKey },
  { to: '/years', label: 'Model Years', key: 'nav.years' as MsgKey },
  { to: '/colors', label: 'Colors', key: 'nav.colors' as MsgKey },
  { to: '/visualizer', label: 'Color Visualizer', key: 'nav.visualizer' as MsgKey },
  { to: '/editions', label: 'Shelby American Editions', key: 'nav.editions' as MsgKey },
  { to: '/history', label: 'Events & History', key: 'nav.history' as MsgKey },
  { to: '/packages', label: 'Packages & Pricing', key: 'nav.packages' as MsgKey },
  { to: '/market', label: 'Market Value', key: 'nav.market' as MsgKey },
  { to: '/performance', label: 'Performance', key: 'nav.performance' as MsgKey },
  { to: '/vin', label: 'VIN Decoder', key: 'nav.vin' as MsgKey },
  { to: '/ownership', label: 'Ownership', key: 'nav.ownership' as MsgKey },
  { to: '/garage', label: 'Garage', key: 'nav.garage' as MsgKey },
  { to: '/planner', label: 'Build Planner', key: 'nav.planner' as MsgKey },
  { to: '/timeline', label: 'Ownership Timeline', key: 'nav.timeline' as MsgKey },
  { to: '/report', label: 'Service History Report', key: 'nav.report' as MsgKey },
  { to: '/achievements', label: 'Achievements', key: 'nav.achievements' as MsgKey },
  { to: '/track', label: 'Track Day Log', key: 'nav.track' as MsgKey },
  { to: '/timer', label: 'Session Timer', key: 'nav.timer' as MsgKey },
  { to: '/drag', label: 'Drag Strip Log', key: 'nav.drag' as MsgKey },
  { to: '/gps', label: 'GPS Meter (approx.)', key: 'nav.gps' as MsgKey },
  { to: '/laptimer', label: 'GPS Lap Timer', key: 'nav.laptimer' as MsgKey },
  { to: '/fuel', label: 'Fuel & Cost', key: 'nav.fuel' as MsgKey },
  { to: '/dyno', label: 'Dyno Log', key: 'nav.dyno' as MsgKey },
  { to: '/tires', label: 'Tire & Wheel Calc', key: 'nav.tires' as MsgKey },
  { to: '/gearing', label: 'Gear & Speed Calc', key: 'nav.gearing' as MsgKey },
  { to: '/tools', label: 'Performance Tools', key: 'nav.tools' as MsgKey },
  { to: '/parts', label: 'Parts & Fluids', key: 'nav.parts' as MsgKey },
  { to: '/guides', label: 'How-to Guides', key: 'nav.guides' as MsgKey },
  { to: '/mods', label: 'Mods & Tuning', key: 'nav.mods' as MsgKey },
  { to: '/compare', label: 'Compare', key: 'nav.compare' as MsgKey },
  { to: '/diff', label: 'Year & Rival Compare', key: 'nav.diff' as MsgKey },
  { to: '/media', label: 'Media', key: 'nav.media' as MsgKey },
  { to: '/community', label: 'Community', key: 'nav.community' as MsgKey },
  { to: '/quiz', label: 'Trivia Quiz', key: 'nav.quiz' as MsgKey },
  { to: '/print', label: 'Print Spec Sheet', key: 'nav.print' as MsgKey },
  { to: '/sources', label: 'Sources', key: 'nav.sources' as MsgKey },
  { to: '/coverage', label: 'Data Coverage', key: 'nav.coverage' as MsgKey },
  { to: '/help', label: 'Help & Guide', key: 'nav.help' as MsgKey },
  { to: '/settings', label: 'Settings', key: 'nav.settings' as MsgKey },
];

const TABS: { to: string; key: MsgKey; icon: string }[] = [
  { to: '/', key: 'nav.home', icon: '⌂' },
  { to: '/specs', key: 'nav.specs', icon: '≡' },
  { to: '/vin', key: 'tab.vin', icon: '#' },
  { to: '/garage', key: 'nav.garage', icon: '⚙' },
  { to: '/search', key: 'nav.search', icon: '⌕' },
];

export default function App() {
  const [settings, setSettings] = useState<Settings>(loadSettings);
  const [prefersDark, setPrefersDark] = useState(() => typeof matchMedia === 'undefined' || matchMedia('(prefers-color-scheme: dark)').matches);
  const [menu, setMenu] = useState(false);
  const loc = useLocation();
  const navigate = useNavigate();
  const theme = resolveTheme(settings.theme, prefersDark);
  setCurrentLang(settings.lang);
  const t = (k: MsgKey) => translate(settings.lang, k);
  const car = useCarState();
  const [, setLangTick] = useState(0);
  // Switching to a language whose chunk is not loaded yet: render English, then re-render when it arrives.
  useEffect(() => { if (!isLangLoaded(settings.lang)) loadLang(settings.lang).then(() => setLangTick((x) => x + 1)).catch(() => undefined); }, [settings.lang]);
  usePrefetch(loc.pathname, ROUTE_LOADERS);

  useEffect(() => {
    if (typeof matchMedia === 'undefined') return;
    const mq = matchMedia('(prefers-color-scheme: dark)');
    const f = () => setPrefersDark(mq.matches);
    mq.addEventListener?.('change', f);
    return () => mq.removeEventListener?.('change', f);
  }, []);
  // First run only: send a brand-new user (no intro done, empty Garage) from Home to the intro.
  useEffect(() => { if (loc.pathname === '/' && needsOnboarding()) navigate('/welcome', { replace: true }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  // Local maintenance notifications (opt-in, permission-gated) are checked once per app open.
  useEffect(() => { checkReminders().catch(() => undefined); }, []);
  useEffect(() => { document.documentElement.dataset.theme = theme; }, [theme]);
  useEffect(() => { document.documentElement.lang = settings.lang; }, [settings.lang]);
  useEffect(() => { saveSettings(settings); }, [settings]);
  useEffect(() => { setMenu(false); window.scrollTo(0, 0); }, [loc.pathname]);

  return (
    <SettingsContext.Provider value={{ settings, setSettings }}>
    <CarContext.Provider value={car}>
    <div className="app">
      <header className="topbar">
        <button className="icon-btn" onClick={() => setMenu((m) => !m)} aria-label={t('chrome.menu')} aria-expanded={menu}>☰</button>
        <NavLink to="/" className="brand"><span className="brand-stripes" aria-hidden />GT500 Companion</NavLink>
        {car.cars.length > 1 && (
          <select className="input car-switch" value={car.active} onChange={(e) => car.switchCar(e.target.value)} aria-label={t('car.switch')}>
            {car.cars.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
          </select>
        )}
        <button className="icon-btn" onClick={() => setSettings({ ...settings, theme: theme === 'dark' ? 'light' : 'dark' })} aria-label={t('chrome.toggleTheme')}>{theme === 'dark' ? '☀' : '☾'}</button>
      </header>
      <nav className={`drawer ${menu ? 'open' : ''}`} aria-label={t('chrome.sections')}>
        {NAV.map((n) => <NavLink key={n.to} to={n.to} end={n.to === '/'}>{t(n.key)}</NavLink>)}
      </nav>
      {menu && <div className="scrim" onClick={() => setMenu(false)} aria-hidden />}
      <a href="#main" className="skip" onClick={(e) => { e.preventDefault(); document.getElementById('main')?.focus(); }}>{t('chrome.skip')}</a>
      <main className="content" id="main" tabIndex={-1}>
        <StatusBar />
        <ErrorBoundary resetKey={loc.pathname} key={car.version}>
        <Suspense fallback={<p className="muted route-loading" role="status">{t('chrome.loading')}</p>}>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/specs" element={<L.Specs />} />
          <Route path="/years" element={<L.ModelYears />} />
          <Route path="/colors" element={<L.Colors />} />
          <Route path="/packages" element={<L.Packages />} />
          <Route path="/performance" element={<L.Performance />} />
          <Route path="/vin" element={<L.Vin />} />
          <Route path="/ownership" element={<L.Ownership />} />
          <Route path="/garage" element={<L.Garage />} />
          <Route path="/mods" element={<L.Mods />} />
          <Route path="/compare" element={<L.Compare />} />
          <Route path="/media" element={<L.Media />} />
          <Route path="/community" element={<L.Community />} />
          <Route path="/sources" element={<L.Sources />} />
          <Route path="/search" element={<L.Search />} />
          <Route path="/planner" element={<L.Planner />} />
          <Route path="/track" element={<L.Track />} />
          <Route path="/gearing" element={<L.Gearing />} />
          <Route path="/tools" element={<L.PerfTools />} />
          <Route path="/settings" element={<L.Settings />} />
          <Route path="/drag" element={<L.Drag />} />
          <Route path="/fuel" element={<L.Fuel />} />
          <Route path="/visualizer" element={<L.Visualizer />} />
          <Route path="/print" element={<L.PrintSheet />} />
          <Route path="/quiz" element={<L.Quiz />} />
          <Route path="/timer" element={<L.Timer />} />
          <Route path="/gps" element={<L.GpsMeter />} />
          <Route path="/laptimer" element={<L.LapTimer />} />
          <Route path="/timeline" element={<L.Timeline />} />
          <Route path="/diff" element={<L.YearCompare />} />
          <Route path="/welcome" element={<L.Welcome />} />
          <Route path="/dyno" element={<L.Dyno />} />
          <Route path="/tires" element={<L.Tires />} />
          <Route path="/share/:data" element={<L.Share />} />
          <Route path="/parts" element={<L.Parts />} />
          <Route path="/guides" element={<L.Guides />} />
          <Route path="/guides/:id" element={<L.Guide />} />
          <Route path="/report" element={<L.Report />} />
          <Route path="/market" element={<L.Market />} />
          <Route path="/achievements" element={<L.Achievements />} />
          <Route path="/editions" element={<L.Editions />} />
          <Route path="/history" element={<L.History />} />
          <Route path="/help" element={<L.Help />} />
          <Route path="/coverage" element={<L.Coverage />} />
          {Gallery && <Route path="/dev/gallery" element={<Gallery />} />}
          <Route path="*" element={<Home />} />
        </Routes>
        </Suspense>
        </ErrorBoundary>
        <footer className="footer">{t('chrome.footer')}</footer>
        <Shortcuts />
        <InstallPrompt />
      </main>
      <nav className="tabbar" aria-label={t('chrome.quick')}>
        {TABS.map((tb) => (
          <NavLink key={tb.to} to={tb.to} end={tb.to === '/'}><span aria-hidden>{tb.icon}</span>{t(tb.key)}</NavLink>
        ))}
      </nav>
    </div>
    </CarContext.Provider>
    </SettingsContext.Provider>
  );
}
