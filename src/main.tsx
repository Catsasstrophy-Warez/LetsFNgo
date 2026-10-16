import React from 'react';
import ReactDOM from 'react-dom/client';
import { HashRouter } from 'react-router';
import App, { PAGES } from './App';
import { watchRegistration } from './lib/sw';
import { shouldRegisterSW } from './lib/platform';
import './styles.css';
import { loadLang } from './lib/i18n';
import { loadSettings } from './lib/units';

const mount = () => ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <HashRouter>
      <App />
    </HashRouter>
  </React.StrictMode>,
);
// English is built in; a Spanish user waits for the (small, cached) dictionary chunk so the first paint is already translated.
const lang = loadSettings().lang;
if (lang === 'en') mount(); else loadLang(lang).then(mount, mount);

if (shouldRegisterSW() && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js')
      .then((reg) => {
        watchRegistration(reg, () => !!navigator.serviceWorker.controller);
        // Check for a new version when the app regains focus.
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') reg.update().catch(() => undefined); });
        // Fetch every lazy route chunk once so the service worker caches them for offline use. Only when a
        // worker exists: without one, warming just spends data (hover/visible-link prefetch still applies).
        const warm = () => { Object.values(PAGES).forEach((f) => f().catch(() => undefined)); loadLang('es').catch(() => undefined); };
        if ('requestIdleCallback' in window) requestIdleCallback(warm); else setTimeout(warm, 2000);
      })
      .catch(() => undefined);
  });
}
