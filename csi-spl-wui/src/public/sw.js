// Spool service worker — makes the WUI an installable PWA, shows its alerts
// on Android (bug A, below) and keeps an app shell for warm loads (W9).
//
// App shell (perf round 4 W9, round-3 P3-10). A warm visit fetched two
// documents in a row - `/`, then the signed-out hop to `/login` - and each
// cost a revalidation round trip (304) before the page could start: ~300 ms
// on fast 4G. Every same-origin GET navigation now goes through the network
// first (navigation preload on, so the request leaves while this worker
// boots) and its HTML is kept in SHELL_CACHE, tagged with its Nuxt buildId.
// A later navigation is answered from that cache WITHOUT the round trip only
// while all of these hold:
//   - the cached document's buildId is the one the network served within the
//     last FRESH_MS (`fresh`, this worker's memory only: a worker that was
//     stopped knows nothing and goes to the network)
//   - it is a plain navigation (request.cache 'default'): a reload, which is
//     how build-watch (SPL-1006) and chunk-reload swap builds, always goes to
//     the network
// So a cached shell is never older than one the network confirmed seconds
// ago - the same as a tab opened seconds earlier. Even then the preloaded
// response is still read in the background; if it names another build the
// tab gets SHELL_STALE and plugins/pwa.client.ts applies build-watch's own
// reload rules. A deploy therefore never sticks behind the old shell.
// Offline, a navigation falls back to the cached document of that path.
// /_nuxt/** stays the HTTP cache's (immutable); /api/** is never cached.
//
// Kill switch: activate deletes every Cache Storage entry except
// SHELL_CACHE, so renaming SHELL_CACHE (or shipping the network-only worker
// again, which deleted them all) drops every shell. Served with max-age=0
// (firebase.json `**`) and registered with updateViaCache 'none', so a new
// copy is picked up on the next navigation.
const SHELL_CACHE = 'spool-shell-v1'
const FRESH_MS = 30000
const SHELL_STALE = 'spool:shell-stale'
const SHELL_ASK = 'spool:shell-ask'
const BUILD_HEADER = 'x-spool-shell-build'
/** the build the network last served, and when: { build, commit, at } */
let fresh = null
/** remember() calls still reading a body: SHELL_ASK answers after them */
const settling = new Set()

self.addEventListener('install', () => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys()
    await Promise.all(keys.filter((k) => k !== SHELL_CACHE).map((k) => caches.delete(k)))
    const reg = self.registration
    if (reg && reg.navigationPreload) {
      try { await reg.navigationPreload.enable() } catch { /* not supported: plain fetch */ }
    }
    await self.clients.claim()
  })())
})

/** The build a generated document names (window.__NUXT__ config), or null. */
function buildOf(html) {
  const b = /buildId:"([0-9A-Za-z-]{8,64})"/.exec(html)
  if (!b) return null
  const c = /buildCommit:"([0-9a-f]{0,40})"/.exec(html)
  return { build: b[1], commit: c ? c[1] : '' }
}

/** A page document of this app: not the API, not a bundle file, not a .json. */
function isShellPath(url) {
  if (url.origin !== self.location.origin) return false
  if (/^\/(api|_nuxt)\//.test(url.pathname)) return false
  const last = url.pathname.slice(url.pathname.lastIndexOf('/') + 1)
  return !/\.[A-Za-z0-9]+$/.test(last) || /\.html$/.test(last)
}

/** Hosting serves the same file whatever the query: one entry per path. */
function shellKey(url) {
  return url.origin + url.pathname
}

/** The preloaded response, or a fetch when there is none. */
function fromNetwork(event) {
  return Promise.resolve(event.preloadResponse).then((r) => r || fetch(event.request))
}

/** Keep a network document as the shell of its path; returns its build or null. */
async function remember(url, res) {
  if (!res || res.status !== 200 || res.type !== 'basic' || res.redirected) return null
  if (!/^text\/html/.test(res.headers.get('content-type') || '')) return null
  const html = await res.text()
  const id = buildOf(html)
  if (!id) return null
  fresh = { ...id, at: Date.now() }
  const headers = new Headers(res.headers)
  /* the body is stored decoded; the CSP and the other security headers stay */
  headers.delete('content-encoding')
  headers.delete('content-length')
  headers.set(BUILD_HEADER, id.build)
  const cache = await caches.open(SHELL_CACHE)
  await cache.put(shellKey(url), new Response(html, { status: 200, statusText: res.statusText, headers }))
  for (const req of await cache.keys()) {
    const old = await cache.match(req)
    if (!old || old.headers.get(BUILD_HEADER) !== id.build) await cache.delete(req)
  }
  return id
}

/** remember(), tracked so a SHELL_ASK never reads a `fresh` about to change. */
function keep(url, res) {
  const job = remember(url, res).catch(() => null)
  settling.add(job)
  return job.finally(() => settling.delete(job))
}

/** Tell the tab a cached shell answered that the network now names `id`. */
async function tellStale(clientId, id) {
  for (let i = 0; clientId && i < 20; i++) {
    const c = await self.clients.get(clientId)
    if (c) {
      c.postMessage({ type: SHELL_STALE, build: id.build, commit: id.commit })
      return
    }
    await new Promise((r) => setTimeout(r, 250))
  }
}

async function navigate(event) {
  const req = event.request
  const url = new URL(req.url)
  const network = fromNetwork(event)
  if (!isShellPath(url)) return network
  const cache = await caches.open(SHELL_CACHE)
  const kept = await cache.match(shellKey(url))
  const served = kept && kept.headers.get(BUILD_HEADER)
  if (served && req.cache === 'default' && fresh && fresh.build === served && Date.now() - fresh.at < FRESH_MS) {
    /* answer now; the preload still revalidates, and a new build reaches the tab */
    event.waitUntil(network
      .then((res) => keep(url, res))
      .then((id) => (id && id.build !== served ? tellStale(event.resultingClientId, id) : undefined))
      .catch(() => {}))
    return kept
  }
  let res
  try {
    res = await network
  } catch (err) {
    /* offline: the last shell of this path, whatever its build */
    if (kept) return kept
    throw err
  }
  event.waitUntil(keep(url, res.clone()))
  return res
}

// The tab's half of SHELL_STALE: a page asks once it is listening (a push
// sent before then is lost - the page queues worker messages only until it
// has parsed, and the app's plugins run later) and gets the build the
// network last served, once every document still being read is settled.
self.addEventListener('message', (event) => {
  const d = event.data
  const port = event.ports && event.ports[0]
  if (!d || d.type !== SHELL_ASK || !port) return
  event.waitUntil(Promise.allSettled([...settling]).then(() => {
    port.postMessage(fresh ? { type: SHELL_STALE, build: fresh.build, commit: fresh.commit } : null)
  }))
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.mode !== 'navigate' || req.method !== 'GET') return
  event.respondWith(navigate(event))
})

// Bug A (t1 5002067f): on Android a new-message alert can only be shown
// through this worker (showAlert in utils/notify.mjs).
//
// CLE-77890 (owner, t1 bd6d7291: tapping an alert "does not jump to the
// actual UI of the announcement, but just keeps me there where I was"): the
// alert's `data` names its message ({ msgId, url: /m/<msg_id> }, see
// notificationTarget). A tap brings an open Spool tab forward and hands it the
// target (NOTIFY_OPEN); the tab answers on the port and opens the message in
// place. A tab that does not answer (a bundle from before this change) is
// navigated to the url; with no tab open, one is opened there.
const NOTIFY_OPEN = 'spool:notification-open'
const ACK_MS = 1500

/**
 * Where a tap goes: the alert's own deep link (a same-origin path), else the
 * feed its tag names (ch:<name> / dm:<peer>, the tag every alert has carried
 * since bug A) - an alert raised by a page still on an older bundle has no
 * data, and its tap must still leave "where I was" (owner, bd6d7291 msg
 * 5f40daa7) - else '/'.
 */
function targetUrl(data, tag) {
  const url = String((data && data.url) || '')
  if (url.startsWith('/') && !url.startsWith('//')) return url
  const t = String(tag || '')
  const ch = t.startsWith('ch:') ? t.slice(3) : ''
  if (ch) return '/channel/' + encodeURIComponent(ch)
  const dm = t.startsWith('dm:') ? t.slice(3) : ''
  if (dm) return '/dm/' + encodeURIComponent(dm)
  return '/'
}

/** Post the target to one tab; true once it answers, false after ACK_MS. */
function handOver(client, msg) {
  return new Promise((resolve) => {
    let done = false
    const ch = new MessageChannel()
    const finish = (ok) => {
      if (done) return
      done = true
      ch.port1.close()
      resolve(ok)
    }
    ch.port1.onmessage = () => finish(true)
    setTimeout(() => finish(false), ACK_MS)
    try {
      client.postMessage(msg, [ch.port2])
    } catch {
      finish(false)
    }
  })
}

async function openFromNotification(data, tag) {
  const url = targetUrl(data, tag)
  const msg = { type: NOTIFY_OPEN, msgId: String((data && data.msgId) || ''), url }
  const tabs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
  /* the tab the reader last looked at first */
  const tab = tabs.find((c) => c.focused) || tabs.find((c) => c.visibilityState === 'visible') || tabs[0]
  if (tab) {
    let win = tab
    try {
      if ('focus' in tab) win = (await tab.focus()) || tab
    } catch { /* focus needs the click's activation; the hand-over still runs */ }
    if (url === '/') return win
    if (await handOver(win, msg)) return win
    if ('navigate' in win) {
      try {
        return await win.navigate(url)
      } catch { /* an uncontrolled tab cannot be navigated from here */ }
    }
  }
  if (self.clients.openWindow) return self.clients.openWindow(url)
  return undefined
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  event.waitUntil(openFromNotification(event.notification.data, event.notification.tag))
})
