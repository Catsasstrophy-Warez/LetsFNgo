// Offline service worker. The build replaces __BUILD__ and the PRECACHE marker (see vite.config.ts),
// so every deploy gets its own cache and old caches are deleted on activate.
const VERSION = '__BUILD__';
const CACHE = `gt500-${VERSION}`;
const PRECACHE = ['./', './index.html', './manifest.webmanifest', './icon.svg', './icon-192.png', './icon-maskable-192.png' /*__ASSETS__*/];

self.addEventListener('install', (e) => {
  // Precache individually so one missing file does not abort the install. No skipWaiting here:
  // the page shows "Update ready" and posts SKIP_WAITING when the user taps Reload.
  e.waitUntil(caches.open(CACHE).then((c) => Promise.all(PRECACHE.map((u) => c.add(u).catch(() => undefined)))));
});
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k.startsWith('gt500-') && k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

/** Only cache complete, same-origin, non-redirected successes. */
const cacheable = (r) => r && r.ok && r.type === 'basic' && !r.redirected;
function put(req, r) { if (cacheable(r)) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return r; }

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then((r) => { if (cacheable(r)) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put('./index.html', copy)); } return r; })
      .catch(() => caches.match('./index.html')));
    return;
  }
  // Hashed build assets never change: cache-first. Everything else (manifest, icons): network-first.
  if (url.pathname.includes('/assets/')) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((r) => put(req, r))));
    return;
  }
  e.respondWith(fetch(req).then((r) => put(req, r)).catch(() => caches.match(req)));
});

// Tapping a maintenance notification focuses the app (or opens it) on the Garage. Only same-scope URLs are used;
// the notification payload is never treated as a URL.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const target = new URL('./#/garage', self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((cs) => {
    const c = cs.find((x) => x.url.startsWith(self.registration.scope));
    return c ? c.focus().then((w) => (w && 'navigate' in w ? w.navigate(target) : w)) : self.clients.openWindow(target);
  }));
});
