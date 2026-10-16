import React from 'react';
import ReactDOM from 'react-dom/client';
import { HashRouter } from 'react-router';
import App, { PAGES } from './App';
import { watchRegistration } from './lib/sw';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <HashRouter>
      <App />
    </HashRouter>
  </React.StrictMode>,
);

if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js')
      .then((reg) => {
        watchRegistration(reg, () => !!navigator.serviceWorker.controller);
        // Check for a new version when the app regains focus.
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') reg.update().catch(() => undefined); });
      })
      .catch(() => undefined);
    // Fetch every lazy route chunk once so the service worker caches them for offline use.
    const warm = () => Object.values(PAGES).forEach((f) => f().catch(() => undefined));
    if ('requestIdleCallback' in window) requestIdleCallback(warm); else setTimeout(warm, 2000);
  });
}
