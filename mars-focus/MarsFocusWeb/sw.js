/* Mars Focus — offline cache for the app shell. Bump the version whenever
   any shell file changes so installed PWAs pick up the update. */
const CACHE_PREFIX = "track-on-me-";
const CACHE = `${CACHE_PREFIX}v8`;
const SHELL = ["./", "index.html", "style.css", "storage-lock.js", "app.js", "manifest.webmanifest", "icon-192.png", "icon-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE)
      // cache: "reload" bypasses the HTTP cache so a new SW version can never
      // repopulate its cache with stale shell files.
      .then((cache) => cache.addAll(SHELL.map((url) => new Request(url, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith(CACHE_PREFIX) && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  // Never intercept the coach's API calls — network only.
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith(
    caches.open(CACHE).then((cache) => cache.match(event.request)).then((cached) => cached || fetch(event.request))
  );
});
