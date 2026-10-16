import { Suspense, lazy, useEffect, useState } from 'react';
import { NavLink, Route, Routes, useLocation } from 'react-router-dom';
import { load, save } from './lib/storage';
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
};
const L = Object.fromEntries(Object.entries(PAGES).map(([k, f]) => [k, lazy(f)])) as Record<keyof typeof PAGES, React.LazyExoticComponent<() => JSX.Element>>;

export const NAV = [
  { to: '/', label: 'Home' },
  { to: '/specs', label: 'Specs' },
  { to: '/years', label: 'Model Years' },
  { to: '/colors', label: 'Colors' },
  { to: '/packages', label: 'Packages & Pricing' },
  { to: '/performance', label: 'Performance' },
  { to: '/vin', label: 'VIN Decoder' },
  { to: '/ownership', label: 'Ownership' },
  { to: '/garage', label: 'Garage' },
  { to: '/planner', label: 'Build Planner' },
  { to: '/track', label: 'Track Day Log' },
  { to: '/gearing', label: 'Gear & Speed Calc' },
  { to: '/tools', label: 'Performance Tools' },
  { to: '/mods', label: 'Mods & Tuning' },
  { to: '/compare', label: 'Compare' },
  { to: '/media', label: 'Media' },
  { to: '/community', label: 'Community' },
  { to: '/sources', label: 'Sources' },
];

const TABS = [
  { to: '/', label: 'Home', icon: '⌂' },
  { to: '/specs', label: 'Specs', icon: '≡' },
  { to: '/vin', label: 'VIN', icon: '#' },
  { to: '/garage', label: 'Garage', icon: '⚙' },
  { to: '/search', label: 'Search', icon: '⌕' },
];

type Theme = 'dark' | 'light';

export default function App() {
  const [theme, setTheme] = useState<Theme>(() => load<Theme>('gt500.theme', 'dark'));
  const [menu, setMenu] = useState(false);
  const loc = useLocation();

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    save('gt500.theme', theme);
  }, [theme]);
  useEffect(() => { setMenu(false); window.scrollTo(0, 0); }, [loc.pathname]);

  return (
    <div className="app">
      <header className="topbar">
        <button className="icon-btn" onClick={() => setMenu((m) => !m)} aria-label="Menu" aria-expanded={menu}>☰</button>
        <NavLink to="/" className="brand"><span className="brand-stripes" aria-hidden />GT500 Companion</NavLink>
        <button className="icon-btn" onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')} aria-label="Toggle theme">{theme === 'dark' ? '☀' : '☾'}</button>
      </header>
      <nav className={`drawer ${menu ? 'open' : ''}`} aria-label="Sections">
        {NAV.map((n) => <NavLink key={n.to} to={n.to} end={n.to === '/'}>{n.label}</NavLink>)}
      </nav>
      {menu && <div className="scrim" onClick={() => setMenu(false)} aria-hidden />}
      <a href="#main" className="skip" onClick={(e) => { e.preventDefault(); document.getElementById('main')?.focus(); }}>Skip to content</a>
      <main className="content" id="main" tabIndex={-1}>
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
          <Route path="*" element={<Home />} />
        </Routes>
        </Suspense>
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
  );
}
