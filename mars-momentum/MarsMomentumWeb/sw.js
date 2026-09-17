/* Mars Momentum — offline cache for the app shell. Bump the version whenever
   any shell file changes so installed PWAs pick up the update. */
const CACHE = "mars-tracking-v13";
const SHELL = ["./", "index.html", "style.css", "app.js", "sync-core.mjs", "storage-lock.mjs", "document-store.mjs", "manifest.webmanifest", "icon-192.png", "icon-512.png"];

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
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("mars-tracking-") && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  // Never serve sync API calls from cache.
  if (new URL(event.request.url).pathname.startsWith("/api/")) return;
  event.respondWith(
    caches.open(CACHE).then((cache) => cache.match(event.request)).then((cached) => cached || fetch(event.request))
  );
});
