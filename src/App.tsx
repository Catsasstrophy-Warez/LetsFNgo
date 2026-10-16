import { Suspense, lazy, useEffect, useState } from 'react';
import { NavLink, Route, Routes, useLocation, useNavigate } from 'react-router';
import { needsOnboarding } from './lib/onboarding';
import { loadSettings, resolveTheme, saveSettings, type Settings } from './lib/units';
import { SettingsContext } from './components/SettingsContext';
import { ErrorBoundary } from './components/ErrorBoundary';
import { StatusBar } from './components/StatusBar';
import Home from './pages/Home';

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
};
const L = Object.fromEntries(Object.entries(PAGES).map(([k, f]) => [k, lazy(f)])) as Record<keyof typeof PAGES, React.LazyExoticComponent<() => JSX.Element>>;

export const NAV = [
  { to: '/', label: 'Home' },
  { to: '/specs', label: 'Specs' },
  { to: '/years', label: 'Model Years' },
  { to: '/colors', label: 'Colors' },
  { to: '/visualizer', label: 'Color Visualizer' },
  { to: '/packages', label: 'Packages & Pricing' },
  { to: '/performance', label: 'Performance' },
  { to: '/vin', label: 'VIN Decoder' },
  { to: '/ownership', label: 'Ownership' },
  { to: '/garage', label: 'Garage' },
  { to: '/planner', label: 'Build Planner' },
  { to: '/timeline', label: 'Ownership Timeline' },
  { to: '/track', label: 'Track Day Log' },
  { to: '/timer', label: 'Session Timer' },
  { to: '/drag', label: 'Drag Strip Log' },
  { to: '/gps', label: 'GPS Meter (approx.)' },
  { to: '/fuel', label: 'Fuel & Cost' },
  { to: '/gearing', label: 'Gear & Speed Calc' },
  { to: '/tools', label: 'Performance Tools' },
  { to: '/mods', label: 'Mods & Tuning' },
  { to: '/compare', label: 'Compare' },
  { to: '/diff', label: 'Year & Rival Compare' },
  { to: '/media', label: 'Media' },
  { to: '/community', label: 'Community' },
  { to: '/quiz', label: 'Trivia Quiz' },
  { to: '/print', label: 'Print Spec Sheet' },
  { to: '/sources', label: 'Sources' },
  { to: '/settings', label: 'Settings' },
];

const TABS = [
  { to: '/', label: 'Home', icon: '⌂' },
  { to: '/specs', label: 'Specs', icon: '≡' },
  { to: '/vin', label: 'VIN', icon: '#' },
  { to: '/garage', label: 'Garage', icon: '⚙' },
  { to: '/search', label: 'Search', icon: '⌕' },
];

export default function App() {
  const [settings, setSettings] = useState<Settings>(loadSettings);
  const [prefersDark, setPrefersDark] = useState(() => typeof matchMedia === 'undefined' || matchMedia('(prefers-color-scheme: dark)').matches);
  const [menu, setMenu] = useState(false);
  const loc = useLocation();
  const navigate = useNavigate();
  const theme = resolveTheme(settings.theme, prefersDark);

  useEffect(() => {
    if (typeof matchMedia === 'undefined') return;
    const mq = matchMedia('(prefers-color-scheme: dark)');
    const f = () => setPrefersDark(mq.matches);
    mq.addEventListener?.('change', f);
    return () => mq.removeEventListener?.('change', f);
  }, []);
  // First run only: send a brand-new user (no intro done, empty Garage) from Home to the intro.
  useEffect(() => { if (loc.pathname === '/' && needsOnboarding()) navigate('/welcome', { replace: true }); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { document.documentElement.dataset.theme = theme; }, [theme]);
  useEffect(() => { saveSettings(settings); }, [settings]);
  useEffect(() => { setMenu(false); window.scrollTo(0, 0); }, [loc.pathname]);

  return (
    <SettingsContext.Provider value={{ settings, setSettings }}>
    <div className="app">
      <header className="topbar">
        <button className="icon-btn" onClick={() => setMenu((m) => !m)} aria-label="Menu" aria-expanded={menu}>☰</button>
        <NavLink to="/" className="brand"><span className="brand-stripes" aria-hidden />GT500 Companion</NavLink>
        <button className="icon-btn" onClick={() => setSettings({ ...settings, theme: theme === 'dark' ? 'light' : 'dark' })} aria-label="Toggle theme">{theme === 'dark' ? '☀' : '☾'}</button>
      </header>
      <nav className={`drawer ${menu ? 'open' : ''}`} aria-label="Sections">
        {NAV.map((n) => <NavLink key={n.to} to={n.to} end={n.to === '/'}>{n.label}</NavLink>)}
      </nav>
      {menu && <div className="scrim" onClick={() => setMenu(false)} aria-hidden />}
      <a href="#main" className="skip" onClick={(e) => { e.preventDefault(); document.getElementById('main')?.focus(); }}>Skip to content</a>
      <main className="content" id="main" tabIndex={-1}>
        <StatusBar />
        <ErrorBoundary resetKey={loc.pathname}>
        <Suspense fallback={<p className="muted" role="status">Loading…</p>}>
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
          <Route path="/timeline" element={<L.Timeline />} />
          <Route path="/diff" element={<L.YearCompare />} />
          <Route path="/welcome" element={<L.Welcome />} />
          <Route path="*" element={<Home />} />
        </Routes>
        </Suspense>
        </ErrorBoundary>
        <footer className="footer">
          Unofficial fan reference. Not affiliated with, endorsed by or sponsored by Ford Motor Company, Shelby American or Carroll Shelby Licensing.
          Names are used for identification only. Verify figures with official documents.
        </footer>
      </main>
      <nav className="tabbar" aria-label="Quick">
        {TABS.map((t) => (
          <NavLink key={t.to} to={t.to} end={t.to === '/'}><span aria-hidden>{t.icon}</span>{t.label}</NavLink>
        ))}
      </nav>
    </div>
    </SettingsContext.Provider>
  );
}
