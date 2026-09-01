// Service worker do PWA Entregador (ADR-023 Fase 1 / D4). Minimal network-first:
// navegação sempre tenta rede, fallback p/ cache de shell. API calls não são
// cacheados (POST/GET em /api/* sempre rede — estado do backend é autoritativo).
// Servido de public/ (padrão doc Next 16: app/guides/progressive-web-apps.md).

const CACHE = "vio10-shell-v1";
const SHELL = ["/driver", "/offline.html", "/icon.svg"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => undefined),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // nunca cacheia mutações
  const url = new URL(req.url);
  if (url.pathname.startsWith("/api/")) return; // backend é autoritativo

  // Navegação (HTML): network-first, fallback cache, fallback offline.
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => undefined);
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match("/offline.html"))),
    );
    return;
  }

  // Estáticos: stale-while-revalidate.
  event.respondWith(
    caches.match(req).then(
      (cached) =>
        cached ||
        fetch(req).then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => undefined);
          return res;
        }),
    ),
  );
});