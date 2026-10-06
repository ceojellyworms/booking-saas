'use strict';

const CACHE_NAME = 'kamidere-booking-shell-v3';
const APP_SHELL = [
  './booking.html',
  './styles.css',
  './booking-theme.css?v=3',
  './app.js?v=3',
  './config.js',
  './icon.svg'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key.startsWith('kamidere-booking-shell-') && key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const requestUrl = new URL(request.url);
  if (request.method !== 'GET' || requestUrl.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request, { cache: 'no-cache' })
        .then(async (response) => {
          if (response.ok) {
            const copy = response.clone();
            try {
              const cache = await caches.open(CACHE_NAME);
              await cache.put(request, copy);
            } catch (error) {
              console.error('Unable to cache the booking page.', error);
            }
          }
          return response;
        })
        .catch(async () => {
          const cachedPage = await caches.match(request, { ignoreSearch: true });
          return cachedPage || caches.match('./booking.html');
        })
    );
    return;
  }

  if (requestUrl.pathname.endsWith('/app.js')
    || requestUrl.pathname.endsWith('/config.js')
    || requestUrl.pathname.endsWith('/styles.css')
    || requestUrl.pathname.endsWith('/booking-theme.css')
    || requestUrl.pathname.endsWith('/icon.svg')) {
    event.respondWith(
      fetch(request, { cache: 'no-cache' })
        .then(async (response) => {
          if (!response.ok) return response;
          const copy = response.clone();
          try {
            const cache = await caches.open(CACHE_NAME);
            await cache.put(request, copy);
          } catch (error) {
            console.error('Unable to update a cached app resource.', error);
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(request);
          if (cached) return cached;
          throw new Error('The app resource is unavailable offline: ' + request.url);
        })
    );
  }
});
