import React from 'react';
import ReactDOM from 'react-dom/client';
import { HashRouter } from 'react-router';
import App, { PAGES } from './App';
import { watchRegistration } from './lib/sw';
import { shouldRegisterSW } from './lib/platform';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <HashRouter>
      <App />
    </HashRouter>
  </React.StrictMode>,
);

if (shouldRegisterSW() && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js')
      .then((reg) => {
        watchRegistration(reg, () => !!navigator.serviceWorker.controller);
        // Check for a new version when the app regains focus.
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') reg.update().catch(() => undefined); });
        // Fetch every lazy route chunk once so the service worker caches them for offline use. Only when a
        // worker exists: without one, warming just spends data (hover/visible-link prefetch still applies).
        const warm = () => Object.values(PAGES).forEach((f) => f().catch(() => undefined));
        if ('requestIdleCallback' in window) requestIdleCallback(warm); else setTimeout(warm, 2000);
      })
      .catch(() => undefined);
  });
}
