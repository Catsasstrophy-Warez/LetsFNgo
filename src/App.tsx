import { useEffect, useState } from 'react';
import { NavLink, Route, Routes, useLocation } from 'react-router-dom';
import { load, save } from './lib/storage';
import Home from './pages/Home';
import Specs from './pages/Specs';
import ModelYears from './pages/ModelYears';
import Colors from './pages/Colors';
import Packages from './pages/Packages';
import Performance from './pages/Performance';
import Vin from './pages/Vin';
import Ownership from './pages/Ownership';
import Garage from './pages/Garage';
import Mods from './pages/Mods';
import Compare from './pages/Compare';
import Media from './pages/Media';
import Community from './pages/Community';
import Sources from './pages/Sources';
import Search from './pages/Search';

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
      {menu && <div className="scrim" onClick={() => setMenu(false)} />}
      <main className="content">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/specs" element={<Specs />} />
          <Route path="/years" element={<ModelYears />} />
          <Route path="/colors" element={<Colors />} />
          <Route path="/packages" element={<Packages />} />
          <Route path="/performance" element={<Performance />} />
          <Route path="/vin" element={<Vin />} />
          <Route path="/ownership" element={<Ownership />} />
          <Route path="/garage" element={<Garage />} />
          <Route path="/mods" element={<Mods />} />
          <Route path="/compare" element={<Compare />} />
          <Route path="/media" element={<Media />} />
          <Route path="/community" element={<Community />} />
          <Route path="/sources" element={<Sources />} />
          <Route path="/search" element={<Search />} />
          <Route path="*" element={<Home />} />
        </Routes>
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
