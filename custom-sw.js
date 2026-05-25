// Self-destructing Service Worker — replaces Actual Budget's aggressive Workbox SW.
// On first activation: clears all caches, then unregisters itself permanently.
// After this runs once, the browser will never have a SW for this origin again.
self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(cacheNames.map(name => caches.delete(name)));
    }).then(() => self.registration.unregister())
  );
});
