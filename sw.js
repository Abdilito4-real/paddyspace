// ================================================================
//  PADDY SPACE — Service Worker  v3.0
//  Cache strategies:
//    Navigation (HTML)  → Network-first, cache fallback
//    Fonts / Images     → Cache-first, background refresh
//    Supabase API       → Network-only (never cache)
//    Static assets      → Stale-while-revalidate
//  Features:
//    Background sync    → Offline reservation + newsletter queue
//    Push notifications → Reservation confirmations
//    Cache pruning      → Auto LRU eviction on images
// ================================================================

const CACHE_NAME   = 'paddy-v3';
const FONT_CACHE   = 'paddy-fonts-v2';
const IMAGE_CACHE  = 'paddy-images-v2';
const MAX_IMG_ENTRIES = 60;

const STATIC_ASSETS = [
  '/',
  '/index.html',
  '/admin.html',
  '/manifest.json',
  '/icons/favicon.svg',
  '/icons/icon-192.svg',
  '/icons/icon-512.svg',
  '/icons/badge-72.svg',
  '/icons/logo-wordmark.svg',
];

// ---- INSTALL: pre-cache app shell ----
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(STATIC_ASSETS))
      .then(() => self.skipWaiting())
      .catch(err => {
        // Partial failure is acceptable — log and continue
        console.warn('[Paddy SW] Pre-cache partial failure:', err);
        self.skipWaiting();
      })
  );
});

// ---- ACTIVATE: prune stale caches ----
self.addEventListener('activate', event => {
  const KEEP = [CACHE_NAME, FONT_CACHE, IMAGE_CACHE];
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => !KEEP.includes(k)).map(k => {
          console.log('[Paddy SW] Deleting old cache:', k);
          return caches.delete(k);
        })
      ))
      .then(() => self.clients.claim())
  );
});

// ---- FETCH: route-based caching strategy ----
self.addEventListener('fetch', event => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Never cache Supabase API or any external REST calls
  if (
    url.hostname.includes('supabase.co') ||
    url.hostname.includes('supabase.io') ||
    url.pathname.startsWith('/rest/') ||
    url.pathname.startsWith('/auth/') ||
    url.pathname.startsWith('/storage/')
  ) return;

  // ── Fonts (Google Fonts / gstatic) — cache-first ──────────────
  if (
    url.hostname.includes('fonts.googleapis.com') ||
    url.hostname.includes('fonts.gstatic.com') ||
    request.destination === 'font'
  ) {
    event.respondWith(cacheFirst(request, FONT_CACHE));
    return;
  }

  // ── Images — cache-first with LRU pruning ─────────────────────
  if (
    request.destination === 'image' ||
    url.hostname.includes('images.unsplash.com') ||
    url.hostname.includes('placehold.co') ||
    /\.(svg|png|jpg|jpeg|webp|gif|ico)$/i.test(url.pathname)
  ) {
    event.respondWith(cacheFirst(request, IMAGE_CACHE, true));
    return;
  }

  // ── HTML navigation — network-first ───────────────────────────
  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(request));
    return;
  }

  // ── Everything else — stale-while-revalidate ──────────────────
  event.respondWith(staleWhileRevalidate(request));
});

// ── Strategy: Cache-first ────────────────────────────────────────
async function cacheFirst(request, cacheName, prune = false) {
  const cache  = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  try {
    const response = await fetch(request);
    if (response.ok) {
      cache.put(request, response.clone());
      if (prune) pruneCache(cacheName, MAX_IMG_ENTRIES);
    }
    return response;
  } catch {
    return new Response('', { status: 408, statusText: 'Offline' });
  }
}

// ── Strategy: Network-first ──────────────────────────────────────
async function networkFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    if (response.ok) cache.put(request, response.clone());
    return response;
  } catch {
    const cached = await cache.match(request);
    return cached || offlineFallback();
  }
}

// ── Strategy: Stale-while-revalidate ─────────────────────────────
async function staleWhileRevalidate(request) {
  const cache  = await caches.open(CACHE_NAME);
  const cached = await cache.match(request);
  const fresh  = fetch(request).then(r => {
    if (r.ok) cache.put(request, r.clone());
    return r;
  }).catch(() => null);
  return cached || fresh;
}

// ── Offline fallback HTML ─────────────────────────────────────────
function offlineFallback() {
  return new Response(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Paddy Space — Offline</title>
  <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{background:#0a0804;color:#f5efe4;font-family:'Georgia',serif;
      display:flex;flex-direction:column;align-items:center;justify-content:center;
      min-height:100vh;text-align:center;padding:2rem}
    .emblem{width:60px;height:60px;border:1px solid #7a5f28;transform:rotate(45deg);
      display:flex;align-items:center;justify-content:center;margin:0 auto 2.5rem}
    .emblem-inner{width:20px;height:20px;background:#c9a84c;opacity:.6}
    h1{font-size:2rem;font-weight:300;color:#c9a84c;margin-bottom:1rem;letter-spacing:.05em}
    p{font-size:.9rem;color:rgba(245,239,228,.55);line-height:1.8;max-width:420px;margin-bottom:2rem}
    a{display:inline-block;border:1px solid #c9a84c;color:#c9a84c;padding:.8rem 2.5rem;
      font-size:.7rem;letter-spacing:.2em;text-transform:uppercase;text-decoration:none;
      transition:all .3s}
    a:hover{background:#c9a84c;color:#0a0804}
    .divider{width:40px;height:1px;background:linear-gradient(to right,transparent,#c9a84c,transparent);
      margin:1.5rem auto}
  </style>
</head>
<body>
  <div class="emblem"><div class="emblem-inner"></div></div>
  <h1>Paddy Space</h1>
  <div class="divider"></div>
  <p>You appear to be offline. Your reservation requests have been saved and will be submitted automatically when your connection is restored.</p>
  <a href="/">Return When Online</a>
</body>
</html>`, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  });
}

// ── LRU cache pruning ─────────────────────────────────────────────
async function pruneCache(cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  const keys  = await cache.keys();
  if (keys.length > maxEntries) {
    await Promise.all(keys.slice(0, keys.length - maxEntries).map(k => cache.delete(k)));
  }
}

// ---- BACKGROUND SYNC ----
self.addEventListener('sync', event => {
  if (event.tag === 'reservation-sync') event.waitUntil(syncReservations());
  if (event.tag === 'newsletter-sync')  event.waitUntil(syncNewsletter());
});

const DB_VERSION = 2;

async function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('paddy-offline', DB_VERSION);
    req.onupgradeneeded = e => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains('queue')) {
        db.createObjectStore('queue', { keyPath: 'id', autoIncrement: true });
      }
      if (!db.objectStoreNames.contains('config')) {
        db.createObjectStore('config', { keyPath: 'key' });
      }
    };
    req.onsuccess = e => {
      resolve(e.target.result);
    };
    req.onerror = e => reject(e);
  });
}

async function getQueueItems(storeName) {
  return new Promise((resolve, reject) => {
    openDB().then(db => {
      if (!db.objectStoreNames.contains(storeName)) { resolve([]); return; }
      const tx  = db.transaction(storeName, 'readonly');
      const req2 = tx.objectStore(storeName).getAll();
      req2.onsuccess = ev => resolve(ev.target.result || []);
      req2.onerror   = ev => reject(ev.target.error);
    }).catch(reject);
  });
}

async function deleteQueueItem(storeName, id) {
  return new Promise((resolve, reject) => {
    openDB().then(db => {
      const tx = db.transaction(storeName, 'readwrite');
      tx.objectStore(storeName).delete(id);
      tx.oncomplete = () => resolve();
      tx.onerror    = ev => reject(ev.target.error);
    }).catch(reject);
  });
}

async function getConfig() {
  try {
    const db = await openDB();
    return new Promise((resolve) => {
      const tx = db.transaction('config', 'readonly');
      const req = tx.objectStore('config').get('supabase');
      req.onsuccess = e => resolve(e.target.result?.value);
      req.onerror = () => resolve(null);
    });
  } catch { return null; }
}

async function saveConfig(cfg) {
  try {
    const db = await openDB();
    const tx = db.transaction('config', 'readwrite');
    tx.objectStore('config').put({ key: 'supabase', value: cfg });
  } catch (e) { console.warn('Config save failed', e); }
}

async function syncReservations() {
  console.log('[Paddy SW] Syncing offline reservations…');
  try {
    const config = await getConfig();
    if (!config) { console.warn('[Paddy SW] No Supabase config found, skipping sync'); return; }

    const items = await getQueueItems('queue');
    const reservations = items.filter(i => i.type === 'reservation');
    for (const item of reservations) {
      try {
        const res = await fetch(`${config.url}/rest/v1/rpc/create_reservation`, {
          method:  'POST',
          headers: {
            'Content-Type':  'application/json',
            'apikey':        config.key,
            'Authorization': `Bearer ${config.key}`,
          },
          body: JSON.stringify({
            p_first_name: item.data.firstName,
            p_last_name:  item.data.lastName,
            p_email:      item.data.email,
            p_phone:      item.data.phone,
            p_room_type:  item.data.roomType,
            p_check_in:   item.data.checkIn,
            p_check_out:  item.data.checkOut,
            p_special_requests: item.data.specialRequests
          }),
        });
        if (res.ok) {
          await deleteQueueItem('queue', item.id);
          console.log('[Paddy SW] Reservation synced:', item.id);
        }
      } catch (err) {
        console.warn('[Paddy SW] Reservation sync item failed:', err);
      }
    }
  } catch (err) {
    console.error('[Paddy SW] syncReservations failed:', err);
  }
}

async function syncNewsletter() {
  console.log('[Paddy SW] Syncing newsletter subscriptions…');
  try {
    const config = await getConfig();
    if (!config) return;

    const items = await getQueueItems('queue');
    const subs  = items.filter(i => i.type === 'newsletter');
    for (const item of subs) {
      try {
        const res = await fetch(`${config.url}/rest/v1/newsletter_subscribers`, {
          method:  'POST',
          headers: {
            'Content-Type':  'application/json',
            'apikey':        config.key,
            'Authorization': `Bearer ${config.key}`,
            'Prefer':        'resolution=merge-duplicates',
          },
          body: JSON.stringify(item.data),
        });
        if (res.ok || res.status === 201) await deleteQueueItem('queue', item.id);
      } catch (err) {
        console.warn('[Paddy SW] Newsletter sync item failed:', err);
      }
    }
  } catch (err) {
    console.error('[Paddy SW] syncNewsletter failed:', err);
  }
}

// ---- PUSH NOTIFICATIONS ----
self.addEventListener('push', event => {
  const data = event.data ? event.data.json() : {};
  const options = {
    body:     data.body    || 'Your Paddy Space reservation has been confirmed.',
    icon:     '/icons/icon-192.svg',
    badge:    '/icons/badge-72.svg',
    vibrate:  [100, 50, 100],
    tag:      data.tag     || 'paddy-notification',
    renotify: true,
    data:     { url: data.url || '/' },
    actions: [
      { action: 'view',    title: 'View Details' },
      { action: 'dismiss', title: 'Dismiss'      },
    ],
  };
  event.waitUntil(
    self.registration.showNotification(data.title || 'Paddy Space', options)
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  if (event.action === 'dismiss') return;
  const target = event.notification.data?.url || '/';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(wins => {
        const existing = wins.find(w => w.url.includes(self.location.origin));
        if (existing) { existing.focus(); existing.navigate(target); }
        else clients.openWindow(target);
      })
  );
});

// ---- MESSAGES FROM PAGE ----
self.addEventListener('message', event => {
  if (event.data?.type === 'SKIP_WAITING') self.skipWaiting();
  if (event.data?.type === 'CLEAR_CACHE') {
    caches.keys()
      .then(keys => Promise.all(keys.map(k => caches.delete(k))))
      .then(() => event.source?.postMessage({ type: 'CACHE_CLEARED' }));
  }
  if (event.data?.type === 'SET_CONFIG') {
    event.waitUntil(saveConfig(event.data.config));
    console.log('[Paddy SW] Configuration updated');
  }
});
