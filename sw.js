// Service worker sederhana: cache shell aplikasi agar bisa dibuka cepat / dipasang di HP.
const CACHE = "driver-ojol-v2";
const SHELL = ["./", "./index.html", "./config.js", "./manifest.webmanifest", "./icon.svg", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;
  // Jangan cache API Supabase & tile peta
  if (url.hostname.includes("supabase") || url.hostname.includes("tile.openstreetmap")) return;
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        if (url.origin === location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(e.request, copy));
        }
        return res;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("./index.html")))
  );
});
